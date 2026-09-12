import CUSBShim

/// USB connection speed.
public enum USBSpeed: String, Sendable, Equatable {
    case unknown
    case low
    case full
    case high
    case superSpeed
    case superSpeedPlus

    static func from(_ shim: uhs_speed) -> USBSpeed {
        switch shim {
        case UHS_SPEED_LOW: return .low
        case UHS_SPEED_FULL: return .full
        case UHS_SPEED_HIGH: return .high
        case UHS_SPEED_SUPER: return .superSpeed
        case UHS_SPEED_SUPER_PLUS: return .superSpeedPlus
        default: return .unknown
        }
    }
}

/// One interface (default altsetting) of the active configuration.
public struct USBProbeInterface: Sendable, Equatable, Identifiable {
    public let interface: USBInterfaceDescriptor
    public let endpoints: [USBEndpointDescriptor]

    public var id: UInt8 { interface.interfaceNumber }

    /// The ADB class tuple 0xFF/0x42/0x01 from the PRD.
    public var isADBInterface: Bool {
        return interface.interfaceClass == 0xFF
            && interface.interfaceSubclass == 0x42
            && interface.interfaceProtocol == 0x01
    }
}

/// A discovered device snapshot: descriptor, speed, location, and the active
/// configuration's interfaces/endpoints.
public struct USBProbeDevice: Sendable, Equatable, Identifiable {
    public let busNumber: UInt8
    public let deviceAddress: UInt8
    public let descriptor: USBDeviceDescriptor
    public let speed: USBSpeed
    public let interfaces: [USBProbeInterface]

    public var id: String { "\(busNumber).\(deviceAddress)" }

    public var adbInterfaces: [USBProbeInterface] {
        interfaces.filter(\.isADBInterface)
    }
}
