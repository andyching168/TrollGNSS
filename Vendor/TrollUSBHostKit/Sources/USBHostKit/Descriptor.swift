import CUSBShim

/// Immutable descriptor values returned by the host stack.
/// All values are Sendable and safe to hand across isolation boundaries.

public struct USBDeviceDescriptor: Sendable, Equatable, Hashable {
    public let usbVersion: UInt16
    public let deviceClass: UInt8
    public let deviceSubclass: UInt8
    public let deviceProtocol: UInt8
    public let maxPacketSize0: UInt8
    public let vendorID: UInt16
    public let productID: UInt16
    public let deviceVersion: UInt16
    public let manufacturerIndex: UInt8
    public let productIndex: UInt8
    public let serialNumberIndex: UInt8
    public let numberOfConfigurations: UInt8
    /// Bus location (unstable across reboots).
    public let locationID: UInt64

    public init(usbVersion: UInt16,
                deviceClass: UInt8,
                deviceSubclass: UInt8,
                deviceProtocol: UInt8,
                maxPacketSize0: UInt8,
                vendorID: UInt16,
                productID: UInt16,
                deviceVersion: UInt16,
                manufacturerIndex: UInt8,
                productIndex: UInt8,
                serialNumberIndex: UInt8,
                numberOfConfigurations: UInt8,
                locationID: UInt64) {
        self.usbVersion = usbVersion
        self.deviceClass = deviceClass
        self.deviceSubclass = deviceSubclass
        self.deviceProtocol = deviceProtocol
        self.maxPacketSize0 = maxPacketSize0
        self.vendorID = vendorID
        self.productID = productID
        self.deviceVersion = deviceVersion
        self.manufacturerIndex = manufacturerIndex
        self.productIndex = productIndex
        self.serialNumberIndex = serialNumberIndex
        self.numberOfConfigurations = numberOfConfigurations
        self.locationID = locationID
    }
}

public struct USBInterfaceDescriptor: Sendable, Equatable {
    public let interfaceNumber: UInt8
    public let alternateSetting: UInt8
    public let numberOfEndpoints: UInt8
    public let interfaceClass: UInt8
    public let interfaceSubclass: UInt8
    public let interfaceProtocol: UInt8
    public let interfaceIndex: UInt8

    public init(interfaceNumber: UInt8,
                alternateSetting: UInt8,
                numberOfEndpoints: UInt8,
                interfaceClass: UInt8,
                interfaceSubclass: UInt8,
                interfaceProtocol: UInt8,
                interfaceIndex: UInt8) {
        self.interfaceNumber = interfaceNumber
        self.alternateSetting = alternateSetting
        self.numberOfEndpoints = numberOfEndpoints
        self.interfaceClass = interfaceClass
        self.interfaceSubclass = interfaceSubclass
        self.interfaceProtocol = interfaceProtocol
        self.interfaceIndex = interfaceIndex
    }
}

public struct USBEndpointDescriptor: Sendable, Equatable {
    public let endpointAddress: UInt8
    public let attributes: UInt8
    public let maxPacketSize: UInt16
    public let interval: UInt8

    /// Direction bit from the endpoint address.
    public var isInput: Bool { endpointAddress & 0x80 != 0 }
    /// Endpoint number (low four bits).
    public var endpointNumber: UInt8 { endpointAddress & 0x0F }

    public init(endpointAddress: UInt8,
                attributes: UInt8,
                maxPacketSize: UInt16,
                interval: UInt8) {
        self.endpointAddress = endpointAddress
        self.attributes = attributes
        self.maxPacketSize = maxPacketSize
        self.interval = interval
    }
}

/// The ADB device class tuple from the PRD.
enum USBDeviceClassTuple {
    static let adb = (classCode: UInt8(0xFF), subclass: UInt8(0x42), protocolCode: UInt8(0x01))

    static func isADB(_ interface: USBInterfaceDescriptor) -> Bool {
        return interface.interfaceClass == adb.classCode
            && interface.interfaceSubclass == adb.subclass
            && interface.interfaceProtocol == adb.protocolCode
    }
}
