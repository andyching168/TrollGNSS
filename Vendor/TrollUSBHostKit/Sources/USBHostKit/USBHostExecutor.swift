import Foundation
import Dispatch
import CUSBShim

/// Single package-owned executor for all libusb work.
///
/// A serial queue runs the quick blocking operations (context lifecycle,
/// open/claim/release, control transfers, string descriptors, async transfer
/// submission and cancellation). A dedicated event thread runs
/// `libusb_handle_events()` so async bulk transfers complete and hotplug
/// events dispatch on time. Nothing on either path ever touches the UI thread.
///
/// The two lanes are deliberately separate: the event loop blocks for up to
/// `eventLoopTick` waiting for kernel events, and serializing that behind the
/// quick queue would add latency to every open/claim. libusb supports
/// concurrent event handling, so a sync control transfer on the queue and the
/// event loop on its own thread cooperate through the shared event
/// infrastructure.
final class USBHostExecutor: @unchecked Sendable {
    let queue: DispatchQueue

    private let eventLock = NSLock()
    private var eventContext: OpaquePointer?
    private var eventLoopRunning = false
    private var eventThread: Thread?

    private static let eventLoopTick = 0.05

    init(label: String) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Starts (or restarts) the event loop against `context`. Safe to call more
    /// than once; the loop only (re)spawns its thread when needed.
    func startEventLoop(context: OpaquePointer) {
        eventLock.lock()
        eventContext = context
        eventLoopRunning = true
        if eventThread == nil {
            let thread = Thread { [weak self] in self?.runEventLoop() }
            thread.name = "USBHostKit.events"
            thread.qualityOfService = .userInitiated
            eventThread = thread
            thread.start()
        }
        eventLock.unlock()
    }

    /// Stops the event loop and waits (bounded) for its thread to exit. Safe
    /// to call even if the loop was never started or already stopped.
    func stopEventLoop() {
        eventLock.lock()
        eventLoopRunning = false
        let thread = eventThread
        eventLock.unlock()

        guard let thread else { return }
        var waited = 0.0
        while thread.isExecuting && waited < 3.0 {
            Thread.sleep(forTimeInterval: 0.01)
            waited += 0.01
        }

        eventLock.lock()
        eventThread = nil
        eventContext = nil
        eventLock.unlock()
    }

    /// Whether the event loop is currently running against a live context.
    var isEventLoopRunning: Bool {
        eventLock.lock()
        defer { eventLock.unlock() }
        return eventLoopRunning && eventContext != nil
    }

    private func runEventLoop() {
        while true {
            eventLock.lock()
            let running = eventLoopRunning
            let context = eventContext
            eventLock.unlock()
            guard running, let context else { break }

            var completed: Int32 = 0
            let rc = uhs_handle_events_timeout(context, Self.eventLoopTick, &completed)
            if rc != UHS_OK {
                // LIBUSB_ERROR_INTERRUPTED is an expected wakeup; any other
                // failure means the context is gone. The next loop iteration
                // re-reads the guard and exits.
            }
        }
    }

    func enqueue(_ body: @escaping () -> Void) {
        queue.async(execute: body)
    }

    func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Owns the libusb context. All access happens on the USBHostExecutor.
final class USBHostContext: @unchecked Sendable {
    private var raw: OpaquePointer?

    func create() throws {
        var context: OpaquePointer?
        let rc = uhs_init(&context)
        guard rc == UHS_OK, let context else {
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }
        raw = context
    }

    func destroy() {
        if let raw {
            uhs_exit(raw)
            self.raw = nil
        }
    }

    func rawContext() throws -> OpaquePointer {
        guard let raw else { throw USBHostError.notStarted }
        return raw
    }

    func withContext<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let raw else { throw USBHostError.notStarted }
        return try body(raw)
    }
}
