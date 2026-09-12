import Foundation
import CUSBShim

/// Stable, Sendable error cases for USB operations.
/// Values are intentional and part of the public surface; do not renumber.
public enum USBHostError: Error, Equatable, Sendable {
    /// The host lacks the entitlement needed to capture the device.
    case permission
    /// The device was unplugged or the session is no longer valid.
    case disconnected
    /// The requested interface cannot be claimed (busy or unsupported layout).
    case interfaceUnavailable
    /// A transfer exceeded its deadline.
    case timeout
    /// The operation was cancelled before it completed.
    case cancelled
    /// An underlying libusb failure with its raw error code.
    case underlyingLibusb(Int32)
    /// The host stack has not been started.
    case notStarted
    /// Any other failure.
    case unknown
}

/// Result of one completed async bulk transfer. Carries the raw native status
/// and `actual_length` so a timed-out read that nevertheless delivered bytes
/// (native `actual_length` > 0) can hand them to the byte-stream framer
/// instead of being treated as "0 bytes valid" and discarded.
public struct USBTransferResult: Sendable, Equatable {
    /// Bytes received on this transfer. On a timed-out read this is the payload
    /// the kernel already delivered before the deadline, not necessarily empty.
    public let data: Data
    /// true when the underlying libusb/darwin transfer ended in a TIMEOUT but
    /// still delivered bytes (a partial or complete payload).
    public let recoveredFromTimeout: Bool
    /// Human-readable raw libusb/uhs status at completion time (e.g. "ok",
    /// "timeout", "interrupted", "no_device"), before any status->error mapping.
    public let nativeStatus: String
    /// Raw native `actual_length` from the completion callback: the byte count
    /// the kernel reported when the transfer completed, including on timeout.
    public let nativeTransferred: Int
}

/// Maps a shim error to the public Swift error.
enum USBHostErrorMapper {
    static func error(from shimError: Int32) -> USBHostError {
        switch shimError {
        case 0:
            return .unknown
        case Int32(UHS_ERROR_ACCESS.rawValue):
            return .permission
        case Int32(UHS_ERROR_NO_DEVICE.rawValue), Int32(UHS_ERROR_NOT_FOUND.rawValue):
            return .disconnected
        case Int32(UHS_ERROR_BUSY.rawValue):
            return .interfaceUnavailable
        case Int32(UHS_ERROR_TIMEOUT.rawValue):
            return .timeout
        case Int32(UHS_ERROR_INTERRUPTED.rawValue):
            return .cancelled
        case Int32(UHS_ERROR_INVALID_PARAM.rawValue), Int32(UHS_ERROR_IO.rawValue),
             Int32(UHS_ERROR_OVERFLOW.rawValue), Int32(UHS_ERROR_PIPE.rawValue),
             Int32(UHS_ERROR_NO_MEM.rawValue), Int32(UHS_ERROR_NOT_SUPPORTED.rawValue),
             Int32(UHS_ERROR_OTHER.rawValue):
            return .underlyingLibusb(shimError)
        default:
            return .unknown
        }
    }
}

extension USBHostError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permission:
            return "Access denied. The com.apple.vm.device-access entitlement is missing or not effective."
        case .disconnected:
            return "The device is no longer connected."
        case .interfaceUnavailable:
            return "The interface is unavailable or already in use."
        case .timeout:
            return "The USB transfer timed out."
        case .cancelled:
            return "The operation was cancelled."
        case .notStarted:
            return "The USB host stack is not running."
        case .underlyingLibusb(let code):
            return "USB error code \(code)."
        case .unknown:
            return "Unknown USB error."
        }
    }
}
