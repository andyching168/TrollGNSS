import Foundation
import CUSBShim

/// Events emitted by the host controller.
public enum USBHostEvent: Sendable, Equatable {
    /// A device matching the ADB class tuple appeared.
    case attached(USBDeviceDescriptor)
    /// A previously attached device disappeared.
    case detached(USBDeviceDescriptor)
}

/// Owns libusb discovery and exposes attach/detach events as an `AsyncSequence`.
///
/// Hotplug callbacks (and async transfer completions) arrive on the
/// package-owned event thread; they are handed to the `events` stream without
/// ever touching UI code. The controller tracks every session it opens and
/// closes them (draining pending transfers) before the context is destroyed.
public actor USBHostController {
    public enum State: Sendable, Equatable {
        case idle
        case running
    }

    private(set) public var state: State = .idle

    /// Attach/detach events. Existing devices at start-up are reported via
    /// `probeDevices()`; this stream carries changes after that snapshot.
    public nonisolated let events: AsyncStream<USBHostEvent>

    private nonisolated let eventSink: USBHostEventSink
    private let executor = USBHostExecutor(label: "USBHostKit.executor")
    private let context = USBHostContext()
    private let hotplug = USBHotplugBridge()
    private var sessions: [USBDeviceSession] = []

    public init() {
        var captured: AsyncStream<USBHostEvent>.Continuation?
        self.events = AsyncStream<USBHostEvent> { continuation in
            captured = continuation
        }
        self.eventSink = USBHostEventSink(continuation: captured!)
    }

    /// Starts discovery: creates the libusb context, registers hotplug
    /// callbacks, and begins the package-owned event loop.
    public func start() async throws {
        guard state == .idle else { return }
        let raw = try await executor.run { () -> OpaquePointer in
            try self.context.create()
            try self.hotplug.register(context: try self.context.rawContext(), onEvent: { [weak self] event in
                self?.emit(event)
            })
            return try self.context.rawContext()
        }
        executor.startEventLoop(context: raw)
        state = .running
    }

    /// Stops discovery: closes tracked sessions (draining pending transfers),
    /// deregisters hotplug, stops the event loop, and destroys the context.
    public func stop() async {
        guard state == .running else { return }
        state = .idle

        let sessions = self.sessions
        self.sessions = []
        for session in sessions {
            await session.close()
        }

        _ = try? await executor.run {
            self.hotplug.deregister()
            // stopEventLoop waits (bounded) for the event thread to exit; it
            // must not run on that thread, so do it from the serial queue.
            self.executor.stopEventLoop()
        }
        _ = try? await executor.run {
            self.context.destroy()
        }
    }

    /// Enumerates currently connected devices with descriptor, speed, location,
    /// and active-configuration interface/endpoint details. Blocks on the
    /// background executor, never on the caller.
    public func probeDevices() async throws -> [USBProbeDevice] {
        try await executor.run {
            try self.context.withContext { context in
                try Self.readDevices(context: context)
            }
        }
    }

    /// Opens the device identified by bus/address and returns a session whose
    /// operations run on the background executor. The controller keeps the
    /// session and closes it on `stop()`.
    public func open(busNumber: UInt8, deviceAddress: UInt8) async throws -> USBDeviceSession {
        let session = try await executor.run { () -> USBDeviceSession in
            let raw = try self.context.withContext { context in
                try Self.openDevice(context: context, busNumber: busNumber, deviceAddress: deviceAddress)
            }
            return USBDeviceSession(backend: LibusbSession(rawHandle: raw), executor: self.executor)
        }
        sessions.append(session)
        return session
    }

    /// Diagnostic: a direct IORegistry listing of the USB IOService classes,
    /// independent of libusb.
    public func registrySummary() async -> String? {
        try? await executor.run { () -> String? in
            guard let raw = uhs_usb_registry_summary() else { return nil }
            defer { uhs_free_string(raw) }
            return String(cString: raw)
        }
    }

    /// Diagnostic: libusb's own debug log captured since context creation.
    public func libusbLog() async -> String? {
        try? await executor.run { () -> String? in
            guard let raw = uhs_get_log() else { return nil }
            defer { uhs_free_string(raw) }
            return String(cString: raw)
        }
    }

    // MARK: - Event emission

    /// Yields an event to the stream. Safe to call from the event-loop thread
    /// (the C hotplug callback runs there).
    nonisolated func emit(_ event: USBHostEvent) {
        eventSink.emit(event)
    }

    // MARK: - libusb calls (executor-bound)

    private static func readDevices(context: OpaquePointer) throws -> [USBProbeDevice] {
        var list = uhs_device_list(devices: nil, count: 0)
        let rc = uhs_get_device_list(context, &list)
        guard rc == UHS_OK else {
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }
        defer { uhs_free_device_list(&list, 1) }

        var result: [USBProbeDevice] = []
        for index in 0..<Int(list.count) {
            guard let device = list.devices?[index] else { continue }
            if let probe = try? readDevice(device) {
                result.append(probe)
            }
        }
        return result
    }

    private static func readDevice(_ device: OpaquePointer) throws -> USBProbeDevice {
        var descriptor = uhs_device_descriptor()
        let rc = uhs_get_device_descriptor(device, &descriptor)
        guard rc == UHS_OK else {
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }

        var speedValue = UHS_SPEED_UNKNOWN
        _ = uhs_get_speed(device, &speedValue)

        var config = uhs_config_info()
        let configRC = uhs_get_active_config(device, &config)

        var interfaces: [USBProbeInterface] = []
        if configRC == UHS_OK {
            for index in 0..<Int(config.b_num_interfaces) {
                let rawInterface = config.interfaces![index]
                var endpoints: [USBEndpointDescriptor] = []
                for endpointIndex in 0..<Int(rawInterface.b_num_endpoints) {
                    let rawEndpoint = rawInterface.endpoints![endpointIndex]
                    endpoints.append(USBEndpointDescriptor(endpointAddress: rawEndpoint.b_endpoint_address,
                                                           attributes: rawEndpoint.bm_attributes,
                                                           maxPacketSize: rawEndpoint.w_max_packet_size,
                                                           interval: rawEndpoint.b_interval))
                }
                interfaces.append(USBProbeInterface(
                    interface: USBInterfaceDescriptor(interfaceNumber: rawInterface.b_interface_number,
                                                      alternateSetting: rawInterface.b_alternate_setting,
                                                      numberOfEndpoints: rawInterface.b_num_endpoints,
                                                      interfaceClass: rawInterface.b_interface_class,
                                                      interfaceSubclass: rawInterface.b_interface_subclass,
                                                      interfaceProtocol: rawInterface.b_interface_protocol,
                                                      interfaceIndex: rawInterface.i_interface),
                    endpoints: endpoints))
            }
            uhs_free_config(&config)
        }

        return USBProbeDevice(
            busNumber: uhs_get_device_bus_number(device),
            deviceAddress: uhs_get_device_address(device),
            descriptor: USBDeviceDescriptor(usbVersion: descriptor.bcd_usb,
                                            deviceClass: descriptor.b_device_class,
                                            deviceSubclass: descriptor.b_device_subclass,
                                            deviceProtocol: descriptor.b_device_protocol,
                                            maxPacketSize0: descriptor.b_max_packet_size0,
                                            vendorID: descriptor.id_vendor,
                                            productID: descriptor.id_product,
                                            deviceVersion: descriptor.bcd_device,
                                            manufacturerIndex: descriptor.i_manufacturer,
                                            productIndex: descriptor.i_product,
                                            serialNumberIndex: descriptor.i_serial_number,
                                            numberOfConfigurations: descriptor.b_num_configurations,
                                            locationID: 0),
            speed: USBSpeed.from(speedValue),
            interfaces: interfaces)
    }

    private static func openDevice(context: OpaquePointer,
                                   busNumber: UInt8,
                                   deviceAddress: UInt8) throws -> OpaquePointer {
        var list = uhs_device_list(devices: nil, count: 0)
        let rc = uhs_get_device_list(context, &list)
        guard rc == UHS_OK else {
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }
        defer { uhs_free_device_list(&list, 1) }

        for index in 0..<Int(list.count) {
            guard let device = list.devices?[index] else { continue }
            if uhs_get_device_bus_number(device) == busNumber,
               uhs_get_device_address(device) == deviceAddress {
                var handle: OpaquePointer?
                let openRC = uhs_open(device, &handle)
                guard openRC == UHS_OK, let handle else {
                    throw USBHostErrorMapper.error(from: openRC.rawValue)
                }
                return handle
            }
        }
        throw USBHostError.disconnected
    }
}

// MARK: - Event sink

/// Owns the `AsyncStream` continuation so hotplug events can be yielded from
/// the event-loop thread (the continuation is Sendable and thread-safe).
final class USBHostEventSink: @unchecked Sendable {
    private let continuation: AsyncStream<USBHostEvent>.Continuation

    init(continuation: AsyncStream<USBHostEvent>.Continuation) {
        self.continuation = continuation
    }

    func emit(_ event: USBHostEvent) {
        continuation.yield(event)
    }
}

// MARK: - Hotplug bridge

/// Bridges libusb hotplug callbacks (event-loop thread) to the controller's
/// event sink. Kept alive for the duration of registration via
/// `Unmanaged.passRetained`; released exactly once by `deregister()`.
final class USBHotplugBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var registrationPointer: UnsafeMutableRawPointer?
    private var onEvent: ((USBHostEvent) -> Void)?

    func register(context: OpaquePointer, onEvent: @escaping (USBHostEvent) -> Void) throws {
        var out: OpaquePointer?
        let userData = Unmanaged.passRetained(self).toOpaque()
        let rc = uhs_hotplug_register(context, uhsHotplugTrampoline, userData, &out)
        guard rc == UHS_OK, let out else {
            Unmanaged<USBHotplugBridge>.fromOpaque(userData).release()
            throw USBHostErrorMapper.error(from: rc.rawValue)
        }
        lock.lock()
        handle = out
        registrationPointer = userData
        self.onEvent = onEvent
        lock.unlock()
    }

    func deregister() {
        lock.lock()
        let handle = self.handle
        let pointer = self.registrationPointer
        self.handle = nil
        self.registrationPointer = nil
        self.onEvent = nil
        lock.unlock()

        guard let handle else { return }
        uhs_hotplug_deregister(handle)
        if let pointer {
            Unmanaged<USBHotplugBridge>.fromOpaque(pointer).release()
        }
    }

    /// Called by the C trampoline on the event-loop thread.
    fileprivate func handle(info: UnsafePointer<uhs_hotplug_info>) {
        let raw = info.pointee
        let descriptor = USBDeviceDescriptor(usbVersion: raw.descriptor.bcd_usb,
                                             deviceClass: raw.descriptor.b_device_class,
                                             deviceSubclass: raw.descriptor.b_device_subclass,
                                             deviceProtocol: raw.descriptor.b_device_protocol,
                                             maxPacketSize0: raw.descriptor.b_max_packet_size0,
                                             vendorID: raw.descriptor.id_vendor,
                                             productID: raw.descriptor.id_product,
                                             deviceVersion: raw.descriptor.bcd_device,
                                             manufacturerIndex: raw.descriptor.i_manufacturer,
                                             productIndex: raw.descriptor.i_product,
                                             serialNumberIndex: raw.descriptor.i_serial_number,
                                             numberOfConfigurations: raw.descriptor.b_num_configurations,
                                             locationID: 0)

        lock.lock()
        let onEvent = self.onEvent
        lock.unlock()

        switch raw.event {
        case UHS_HOTPLUG_ATTACHED:
            onEvent?(.attached(descriptor))
        case UHS_HOTPLUG_DETACHED:
            onEvent?(.detached(descriptor))
        default:
            break
        }
    }
}

private let uhsHotplugTrampoline: @convention(c) (UnsafePointer<uhs_hotplug_info>?, UnsafeMutableRawPointer?) -> Void = { info, userData in
    guard let info, let userData else { return }
    let bridge = Unmanaged<USBHotplugBridge>.fromOpaque(userData).takeUnretainedValue()
    bridge.handle(info: info)
}
