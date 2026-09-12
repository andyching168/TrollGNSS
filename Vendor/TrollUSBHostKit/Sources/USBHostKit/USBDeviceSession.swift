import Foundation
import CUSBShim

/// An opened device session. All operations hop to the shared background
/// executor so they never block the UI thread. `close()` is idempotent and
/// cancels any pending transfer before the underlying handle is closed.
public final class USBDeviceSession: @unchecked Sendable {
    private let backend: any USBBackendSession
    private let executor: USBHostExecutor

    init(backend: any USBBackendSession, executor: USBHostExecutor) {
        self.backend = backend
        self.executor = executor
    }

    deinit {
        // Best-effort safety net for sessions the app forgot to close. The
        // controller always closes its tracked sessions before destroying the
        // context, so in the normal lifecycle the handle is still valid here.
        let backend = self.backend
        let queue = executor.queue
        queue.async { backend.close() }
    }

    /// Whether the session is still considered open.
    public var isOpen: Bool {
        backend.isOpen
    }

    /// Closes the session. Idempotent; safe to call multiple times.
    public func close() async {
        _ = try? await executor.run { [self] in
            backend.close()
        }
    }

    public func claimInterface(_ number: UInt8) async throws {
        try await executor.run { [self] in
            guard backend.isOpen else { throw USBHostError.disconnected }
            try backend.claim(interface: number)
        }
    }

    /// Enables libusb's Darwin capture path before an interface is claimed.
    /// This is required when a system class driver already owns the interface.
    public func setAutoDetachKernelDriver(_ enabled: Bool) async throws {
        try await executor.run { [self] in
            guard backend.isOpen else { throw USBHostError.disconnected }
            try backend.setAutoDetachKernelDriver(enabled)
        }
    }

    public func releaseInterface(_ number: UInt8) async throws {
        try await executor.run { [self] in
            guard backend.isOpen else { throw USBHostError.disconnected }
            try backend.release(interface: number)
        }
    }

    /// Re-enumerates the device, which the peer sees as a physical detach and
    /// re-attach. Use it to make a peer restart whatever it negotiates on
    /// connect: nothing softer reaches a device that believes it is still
    /// connected to the same host.
    ///
    /// This session does not survive the call even when it succeeds. Close it,
    /// wait for the device to reappear, then open the new one.
    public func resetDevice() async throws {
        try await executor.run { [self] in
            guard backend.isOpen else { throw USBHostError.disconnected }
            try backend.resetDevice()
        }
    }

    public func controlTransfer(requestType: UInt8,
                                request: UInt8,
                                value: UInt16,
                                index: UInt16,
                                buffer: Data,
                                timeoutMilliseconds: UInt32) async throws -> Data {
        try await executor.run { [self] in
            guard backend.isOpen else { throw USBHostError.disconnected }
            return try backend.controlTransfer(requestType: requestType,
                                               request: request,
                                               value: value,
                                               index: index,
                                               buffer: buffer,
                                               timeoutMilliseconds: timeoutMilliseconds)
        }
    }

    /// Reads a string descriptor as ASCII (best effort).
    public func stringDescriptor(index: UInt8) async throws -> String {
        try await executor.run { [self] in
            guard backend.isOpen else { throw USBHostError.disconnected }
            return try backend.stringDescriptor(index: index)
        }
    }

    /// Reads up to `length` bytes from `endpoint` on the background executor.
    ///
    /// The read is an asynchronous libusb transfer: Task cancellation cancels
    /// the transfer and returns `.cancelled`, and a cable detach completes it
    /// with `.disconnected`. The caller's continuation is resumed exactly once
    /// regardless of how those events interleave. A timed-out read that still
    /// delivered bytes (native `actual_length` > 0) returns those bytes; use
    /// `bulkReadDetailed` to distinguish that case from a plain success.
    public func bulkRead(endpoint: UInt8, length: Int, timeoutMilliseconds: UInt32) async throws -> Data {
        try await bulkReadDetailed(endpoint: endpoint, length: length, timeoutMilliseconds: timeoutMilliseconds).data
    }

    /// Like `bulkRead`, but returns the raw completion result (delivered bytes,
    /// whether they were recovered from a timeout, and the native status /
    /// actual_length) so the caller can prove what the kernel actually
    /// delivered and count partial-timeout deliveries.
    public func bulkReadDetailed(endpoint: UInt8, length: Int, timeoutMilliseconds: UInt32) async throws -> USBTransferResult {
        let box = TransferBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<USBTransferResult, Error>) in
                let request = PendingTransfer(continuation: continuation, executor: executor, backend: backend)
                box.set(request)
                executor.enqueue {
                    request.submitRead(endpoint: endpoint, length: length, timeoutMilliseconds: timeoutMilliseconds)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Writes `data` to `endpoint` on the background executor. Cancellable like
    /// `bulkRead`. A timed-out write with partial bytes is still an error (a
    /// partial write cannot be safely resumed).
    public func bulkWrite(endpoint: UInt8, data: Data, timeoutMilliseconds: UInt32) async throws {
        let box = TransferBox()
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<USBTransferResult, Error>) in
                let request = PendingTransfer(continuation: continuation, executor: executor, backend: backend)
                box.set(request)
                executor.enqueue {
                    request.submitWrite(endpoint: endpoint, data: data, timeoutMilliseconds: timeoutMilliseconds)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

// MARK: - Task-cancellation plumbing

/// Bridges the `withTaskCancellationHandler` onCancel closure and the executor
/// submission, closing the window where cancellation fires before the
/// `PendingTransfer` exists.
private final class TransferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: PendingTransfer?

    func set(_ request: PendingTransfer) {
        lock.lock()
        self.request = request
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled {
            request.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let request = self.request
        lock.unlock()
        request?.cancel()
    }
}

/// Wraps one async bulk transfer so the underlying continuation is resumed
/// exactly once, even when Task cancellation races with completion or a cable
/// detach. All shared state is guarded by a lock; submission runs on the
/// executor, cancellation may run on any thread, and completion arrives on the
/// event-loop thread.
private final class PendingTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<USBTransferResult, Error>
    private let executor: USBHostExecutor
    private let backend: any USBBackendSession
    private var token: UInt?
    private var finished = false
    private var cancelRequested = false

    init(continuation: CheckedContinuation<USBTransferResult, Error>,
         executor: USBHostExecutor,
         backend: any USBBackendSession) {
        self.continuation = continuation
        self.executor = executor
        self.backend = backend
    }

    /// Executor-bound submission for a read.
    func submitRead(endpoint: UInt8, length: Int, timeoutMilliseconds: UInt32) {
        let token: UInt
        do {
            lock.lock()
            if cancelRequested || finished {
                lock.unlock()
                finish(.failure(USBHostError.cancelled))
                return
            }
            lock.unlock()
            token = try backend.submitBulkRead(endpoint: endpoint,
                                               length: length,
                                               timeoutMilliseconds: timeoutMilliseconds) { [weak self] result in
                self?.finish(result)
            }
        } catch {
            finish(.failure(error))
            return
        }
        adopt(token)
    }

    /// Executor-bound submission for a write.
    func submitWrite(endpoint: UInt8, data: Data, timeoutMilliseconds: UInt32) {
        let token: UInt
        do {
            lock.lock()
            if cancelRequested || finished {
                lock.unlock()
                finish(.failure(USBHostError.cancelled))
                return
            }
            lock.unlock()
            token = try backend.submitBulkWrite(endpoint: endpoint,
                                                data: data,
                                                timeoutMilliseconds: timeoutMilliseconds) { [weak self] result in
                self?.finish(result)
            }
        } catch {
            finish(.failure(error))
            return
        }
        adopt(token)
    }

    /// Task-cancellation entry point; may run on any thread.
    func cancel() {
        lock.lock()
        cancelRequested = true
        let token = self.token
        lock.unlock()
        if let token {
            enqueueCancel(token)
        }
        // If submission has not run yet it sees cancelRequested and finishes
        // immediately without submitting anything.
    }

    private func adopt(_ token: UInt) {
        lock.lock()
        self.token = token
        let shouldCancel = cancelRequested
        lock.unlock()
        if shouldCancel {
            enqueueCancel(token)
        }
    }

    private func enqueueCancel(_ token: UInt) {
        executor.enqueue { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alreadyFinished = self.finished
            self.lock.unlock()
            guard !alreadyFinished else { return }
            self.backend.cancelTransfer(token)
        }
    }

    private func finish<Failure: Error>(_ result: Result<USBTransferResult, Failure>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        token = nil
        lock.unlock()
        continuation.resume(with: result.mapError { $0 as Error })
    }
}
