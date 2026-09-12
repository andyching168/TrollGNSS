import Foundation
import CUSBShim

/// Backend session protocol used by `USBDeviceSession`.
///
/// Implementations are called on the executor's serial queue (with the
/// exception of transfer completion callbacks, which arrive on the event-loop
/// thread). The real implementation wraps the C shim; tests inject a fake.
protocol USBBackendSession: AnyObject, Sendable {
    var isOpen: Bool { get }
    func setAutoDetachKernelDriver(_ enabled: Bool) throws
    func claim(interface: UInt8) throws
    func release(interface: UInt8) throws
    func resetDevice() throws
    func close()
    func controlTransfer(requestType: UInt8,
                         request: UInt8,
                         value: UInt16,
                         index: UInt16,
                         buffer: Data,
                         timeoutMilliseconds: UInt32) throws -> Data
    func stringDescriptor(index: UInt8) throws -> String
    /// Submits an async bulk read. The completion fires exactly once on the
    /// event-loop thread with the raw native status/actual_length. Returns an
    /// opaque token for cancellation.
    func submitBulkRead(endpoint: UInt8,
                        length: Int,
                        timeoutMilliseconds: UInt32,
                        completion: @escaping (Result<USBTransferResult, USBHostError>) -> Void) throws -> UInt
    /// Submits an async bulk write. Same completion contract as `submitBulkRead`.
    func submitBulkWrite(endpoint: UInt8,
                         data: Data,
                         timeoutMilliseconds: UInt32,
                         completion: @escaping (Result<USBTransferResult, USBHostError>) -> Void) throws -> UInt
    func cancelTransfer(_ token: UInt)
}

// MARK: - Real libusb-backed session

/// A real `USBBackendSession` over one opened libusb device handle.
///
/// Close is idempotent and cancels in-flight transfers first, then waits
/// (bounded) for their completions so pending continuations resume and the C
/// tokens are freed before the handle is closed -- libusb would otherwise
/// silently drop in-flight transfers on close and leave callers hanging.
final class LibusbSession: @unchecked Sendable, USBBackendSession {
    private let condition = NSCondition()
    private var rawHandle: OpaquePointer?
    private var activeTokens: Set<UInt> = []

    init(rawHandle: OpaquePointer) {
        self.rawHandle = rawHandle
    }

    var isOpen: Bool {
        condition.lock()
        defer { condition.unlock() }
        return rawHandle != nil
    }

    func close() {
        condition.lock()
        let handle = rawHandle
        rawHandle = nil
        let tokens = Array(activeTokens)
        condition.unlock()

        guard let handle else { return }

        if !tokens.isEmpty {
            for token in tokens {
                if let ptr = OpaquePointer(bitPattern: Int(bitPattern: token)) {
                    uhs_cancel_transfer(ptr)
                }
            }
            let deadline = Date().addingTimeInterval(2.0)
            condition.lock()
            while !activeTokens.isEmpty {
                if !condition.wait(until: deadline) { break }
            }
            let stillPending = !activeTokens.isEmpty
            condition.unlock()
            if stillPending {
                // A cancelled transfer never completed -- the USB pipe is
                // wedged at the kernel level, not just idle. Its eventual
                // completion (if it ever arrives) still runs against this
                // handle, so calling uhs_close/libusb_close now would free
                // device state that completion may still touch, which is
                // exactly the darwin_deref_cached_device/darwin_destroy_device
                // use-after-free seen on device. Leak the handle instead of
                // risking a crash; the pending completion still resumes its
                // caller normally once/if it arrives.
                return
            }
        }
        uhs_close(handle)
    }

    func claim(interface: UInt8) throws {
        let handle = try requireHandle()
        let rc = uhs_claim_interface(handle, interface)
        guard rc == UHS_OK else {
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }
    }

    func setAutoDetachKernelDriver(_ enabled: Bool) throws {
        let handle = try requireHandle()
        let rc = uhs_set_auto_detach_kernel_driver(handle, enabled)
        guard rc == UHS_OK else {
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }
    }

    func release(interface: UInt8) throws {
        let handle = try requireHandle()
        let rc = uhs_release_interface(handle, interface)
        guard rc == UHS_OK else {
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }
    }

    func resetDevice() throws {
        let handle = try requireHandle()
        let rc = uhs_reset_device(handle)
        // LIBUSB_ERROR_NOT_FOUND is the expected outcome of a successful
        // re-enumeration: the device came back as a new one, so the old handle no
        // longer resolves. Report it as success — the caller re-opens either way.
        guard rc == UHS_OK || rc == UHS_ERROR_NO_DEVICE || rc == UHS_ERROR_NOT_FOUND else {
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }
    }

    func controlTransfer(requestType: UInt8,
                         request: UInt8,
                         value: UInt16,
                         index: UInt16,
                         buffer: Data,
                         timeoutMilliseconds: UInt32) throws -> Data {
        let handle = try requireHandle()
        var outBuffer = buffer
        let byteCount = outBuffer.count
        let rc = outBuffer.withUnsafeMutableBytes { outBytes -> uhs_error in
            uhs_control_transfer(handle,
                                 requestType,
                                 request,
                                 value,
                                 index,
                                 outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                 UInt16(byteCount),
                                 timeoutMilliseconds)
        }
        guard rc == UHS_OK else {
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }
        return outBuffer
    }

    func stringDescriptor(index: UInt8) throws -> String {
        let handle = try requireHandle()
        var buffer = [CChar](repeating: 0, count: 256)
        let rc = uhs_get_string_descriptor_ascii(handle, index, &buffer, buffer.count)
        guard rc == UHS_OK else {
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }
        return String(cString: buffer)
    }

    func submitBulkRead(endpoint: UInt8,
                        length: Int,
                        timeoutMilliseconds: UInt32,
                        completion: @escaping (Result<USBTransferResult, USBHostError>) -> Void) throws -> UInt {
        try submitBulk(endpoint: endpoint, data: Data(count: length), timeoutMilliseconds: timeoutMilliseconds, isRead: true, completion: completion)
    }

    func submitBulkWrite(endpoint: UInt8,
                         data: Data,
                         timeoutMilliseconds: UInt32,
                         completion: @escaping (Result<USBTransferResult, USBHostError>) -> Void) throws -> UInt {
        try submitBulk(endpoint: endpoint, data: data, timeoutMilliseconds: timeoutMilliseconds, isRead: false, completion: completion)
    }

    func cancelTransfer(_ token: UInt) {
        guard let ptr = OpaquePointer(bitPattern: Int(bitPattern: token)) else { return }
        _ = uhs_cancel_transfer(ptr)
    }

    // MARK: - Private

    private func requireHandle() throws -> OpaquePointer {
        condition.lock()
        defer { condition.unlock() }
        guard let rawHandle else { throw USBHostError.disconnected }
        return rawHandle
    }

    private func submitBulk(endpoint: UInt8,
                            data: Data,
                            timeoutMilliseconds: UInt32,
                            isRead: Bool,
                            completion: @escaping (Result<USBTransferResult, USBHostError>) -> Void) throws -> UInt {
        let handle = try requireHandle()
        let context = TransferContext(session: self, isRead: isRead, completion: completion)
        var rawToken: OpaquePointer?
        let userData = Unmanaged.passRetained(context).toOpaque()

        // Hold the condition across submit + bookkeeping so a very fast
        // completion on the event thread (which takes the same condition to
        // remove its token) cannot run before the token is registered for
        // close() to drain. uhs_submit_bulk only enqueues the transfer; it
        // does not wait for the completion, so this cannot deadlock.
        var mutableData = data
        let dataCount = mutableData.count
        condition.lock()
        let rc: uhs_error = mutableData.withUnsafeMutableBytes { bytes in
            uhs_submit_bulk(handle,
                            endpoint,
                            bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            Int32(dataCount),
                            timeoutMilliseconds,
                            uhsTransferTrampoline,
                            userData,
                            &rawToken)
        }
        guard rc == UHS_OK, let rawToken else {
            condition.unlock()
            Unmanaged<TransferContext>.fromOpaque(userData).release()
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }

        let token = Self.toToken(rawToken)
        activeTokens.insert(token)
        condition.unlock()
        return token
    }

    /// Called from the transfer completion (event-loop thread).
    func transferCompleted(token: UInt) {
        condition.lock()
        activeTokens.remove(token)
        condition.broadcast()
        condition.unlock()
    }

    fileprivate static func toToken(_ ptr: OpaquePointer) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(ptr))
    }
}

// MARK: - C trampoline

/// Receives async transfer completions from the C shim (event-loop thread).
private let uhsTransferTrampoline: @convention(c) (uhs_error, Int32, UnsafePointer<UInt8>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { status, transferred, data, token, userData in
    guard let userData else { return }
    let context = Unmanaged<TransferContext>.fromOpaque(userData).takeRetainedValue()
    context.handle(status: status, transferred: Int(transferred), data: data, token: token)
}

/// Swift-side holder for one in-flight transfer. Retained (+1) at submit via
/// `Unmanaged.passRetained` and released exactly once by the trampoline.
private final class TransferContext: @unchecked Sendable {
    private let session: LibusbSession
    private let isRead: Bool
    private let completion: (Result<USBTransferResult, USBHostError>) -> Void

    init(session: LibusbSession,
         isRead: Bool,
         completion: @escaping (Result<USBTransferResult, USBHostError>) -> Void) {
        self.session = session
        self.isRead = isRead
        self.completion = completion
    }

    func handle(status: uhs_error, transferred: Int, data: UnsafePointer<UInt8>?, token: OpaquePointer?) {
        let nativeName: String = {
            guard let ptr = uhs_error_name(status) else { return "unknown(\(status.rawValue))" }
            return String(cString: ptr)
        }()
        let bytes = transferred > 0 && data != nil ? Data(bytes: data!, count: transferred) : Data()

        let result: Result<USBTransferResult, USBHostError>
        if status == UHS_OK {
            result = .success(USBTransferResult(data: bytes,
                                                recoveredFromTimeout: false,
                                                nativeStatus: nativeName,
                                                nativeTransferred: transferred))
        } else if isRead, status == UHS_ERROR_TIMEOUT, transferred > 0 {
            // A timed-out bulk IN can still have delivered payload bytes: with
            // USBI_TRANSFER_OS_HANDLES_TIMEOUT, libusb-darwin reports the
            // kernel's byte count on kIOUSBTransactionTimeout in
            // transfer->actual_length (itransfer->transferred += tpriv->size),
            // and libusb core copies that to actual_length for every status.
            // Do NOT throw these bytes away as "0 bytes valid" -- hand them to
            // the framer so a payload whose length is a multiple of the max
            // packet size (which needs a ZLP to terminate a host read, a
            // terminator this iOS stack may drop) can still complete.
            result = .success(USBTransferResult(data: bytes,
                                                recoveredFromTimeout: true,
                                                nativeStatus: nativeName,
                                                nativeTransferred: transferred))
        } else {
            result = .failure(USBHostErrorMapper.error(from: status.rawValue))
        }

        if let token {
            session.transferCompleted(token: LibusbSession.toToken(token))
            uhs_free_transfer(token)
        }
        completion(result)
    }
}
