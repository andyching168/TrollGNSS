import Foundation
import NMEACore
import USBHostKit

@MainActor
final class GPSAppModel: ObservableObject {
    enum ConnectionState: Equatable {
        case stopped, scanning, ready, connecting, connected, failed(String)
    }

    @Published private(set) var connectionState: ConnectionState = .stopped
    @Published private(set) var candidates: [SerialCandidate] = []
    @Published private(set) var snapshot = NMEASnapshot()
    @Published private(set) var rawSentences: [RawSentence] = []
    @Published private(set) var registrySummary = ""
    @Published private(set) var libusbLog = ""
    @Published private(set) var failureStage = ""
    @Published private(set) var diagnosticsSavedAt: Date?
    @Published var baudRate = 9_600
    @Published var selectedCandidateID: String?

    let supportedBaudRates = [4_800, 9_600, 19_200, 38_400, 57_600, 115_200]
    private let controller = USBHostController()
    let locationInjector = SystemLocationInjector()
    private var connection: (any GPSByteConnection)?
    private var parser = NMEAParser()
    private var framer = NMEAByteFramer()
    private var eventTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var started = false
    private var resumeInjectionConnection = false

    var selectedCandidate: SerialCandidate? {
        candidates.first { $0.id == selectedCandidateID }
    }

    func start() async {
        guard !started else { return }
        connectionState = .scanning
        do {
            try await controller.start()
            started = true
            await scan()
            eventTask = Task { [weak self] in
                guard let self else { return }
                for await _ in controller.events {
                    if Task.isCancelled { return }
                    await self.scan()
                }
            }
        } catch {
            started = false
            setFailure(stage: L("stage.start_usb"), error: error)
            await refreshDiagnostics()
        }
    }

    func scan() async {
        guard connection == nil else { return }
        connectionState = .scanning
        do {
            let devices = try await controller.probeDevices()
            candidates = SerialDetector.candidates(in: devices)
            if selectedCandidate == nil { selectedCandidateID = candidates.first?.id }
            connectionState = .ready
        } catch {
            setFailure(stage: L("stage.enumerate_usb"), error: error)
        }
        await refreshDiagnostics()
        if resumeInjectionConnection, locationInjector.enabled, selectedCandidate != nil {
            resumeInjectionConnection = false
            await connectSelected()
        }
    }

    func connectSelected() async {
        guard connection == nil, let candidate = selectedCandidate else { return }
        connectionState = .connecting
        do {
            var ports: [String] = []
            do {
                ports = try FileManager.default.contentsOfDirectory(atPath: "/dev").filter { $0.hasPrefix("cu.usbmodem") }
            } catch {
                // Diagnostic fallback for this receiver: SSH verified this
                // exact node exists. Directory listing and opening a node
                // can have different sandbox permissions.
                if candidate.device.descriptor.vendorID == 0x1546,
                   candidate.device.descriptor.productID == 0x01A8 {
                    ports = ["cu.usbmodem101"]
                } else {
                    throw USBSerialOpenError(stage: L("stage.enumerate_serial"), underlying: error)
                }
            }
            let serial: any GPSByteConnection
            if candidate.chipset == .cdcACM, candidates.count == 1, ports.count == 1 {
                do {
                    serial = try NativeSerialConnection(path: "/dev/" + ports[0], baudRate: baudRate)
                } catch {
                    throw USBSerialOpenError(stage: L("stage.open_native_serial", ports[0]), underlying: error)
                }
            } else {
            let session = try await controller.open(busNumber: candidate.device.busNumber,
                                                    deviceAddress: candidate.device.deviceAddress)
            let usbSerial = USBSerialConnection(session: session, candidate: candidate)
            do {
                try await usbSerial.open(baudRate: baudRate)
            } catch {
                await session.close()
                throw error
            }
            serial = usbSerial
            }
            failureStage = ""
            connection = serial
            parser = NMEAParser()
            framer = NMEAByteFramer()
            snapshot = parser.snapshot
            rawSentences = []
            connectionState = .connected
            readTask = Task { [weak self] in await self?.readLoop(serial) }
        } catch {
            if let serialError = error as? USBSerialOpenError {
                setFailure(stage: serialError.stage, error: serialError.underlying)
            } else {
                setFailure(stage: L("stage.open_usb"), error: error)
            }
            await refreshDiagnostics()
        }
    }

    func disconnect() async {
        resumeInjectionConnection = false
        locationInjector.unavailable(L("injector.serial_disconnected_short"))
        readTask?.cancel()
        readTask = nil
        let active = connection
        connection = nil
        await active?.close()
        connectionState = .ready
        await scan()
    }

    func refreshDiagnostics() async {
        registrySummary = await controller.registrySummary() ?? L("diagnostics.no_ioreg")
        libusbLog = await controller.libusbLog() ?? L("diagnostics.no_libusb")
        saveDiagnostics()
    }

    func retryUSBHost() async {
        locationInjector.unavailable(L("injector.usb_restarting"))
        readTask?.cancel()
        readTask = nil
        eventTask?.cancel()
        eventTask = nil
        let active = connection
        connection = nil
        await active?.close()
        await controller.stop()
        started = false
        failureStage = ""
        await start()
    }

    func loadDemoData() {
        locationInjector.stop() // Demo coordinates must never enter system location.
        parser = NMEAParser()
        let lines = [
            Self.sentence("GPRMC,092751.00,A,2502.5186,N,12133.2367,E,3.25,42.5,120926,,,A"),
            Self.sentence("GPGGA,092751.00,2502.5186,N,12133.2367,E,1,08,0.9,12.3,M,18.0,M,,"),
            Self.sentence("GPGSA,A,3,02,05,12,15,18,21,25,29,,,,,1.5,0.9,1.2"),
            Self.sentence("GPGSV,2,1,08,02,62,045,42,05,48,133,38,12,35,250,31,15,20,310,28"),
            Self.sentence("GPGSV,2,2,08,18,72,190,45,21,15,082,25,25,40,015,36,29,28,220,33"),
        ]
        rawSentences = []
        for line in lines {
            rawSentences.insert(parser.ingest(line), at: 0)
        }
        snapshot = parser.snapshot
    }

    private func readLoop(_ serial: any GPSByteConnection) async {
        while !Task.isCancelled {
            do {
                let data = try await serial.read()
                for line in framer.append(data) {
                    let raw = parser.ingest(line)
                    locationInjector.consume(raw, snapshot: parser.snapshot)
                    rawSentences.insert(raw, at: 0)
                    if rawSentences.count > 500 { rawSentences.removeLast(rawSentences.count - 500) }
                }
                snapshot = parser.snapshot
            } catch let error as USBHostError where error == .timeout {
                continue
            } catch let error as USBHostError where error == .cancelled {
                return
            } catch {
                connection = nil
                resumeInjectionConnection = locationInjector.enabled
                locationInjector.unavailable(L("injector.serial_disconnected", error.localizedDescription))
                setFailure(stage: L("stage.read_nmea"), error: error)
                await serial.close()
                await refreshDiagnostics()
                return
            }
        }
    }

    private static func sentence(_ payload: String) -> String {
        let checksum = payload.utf8.reduce(UInt8(0), ^)
        return "$\(payload)*\(String(format: "%02X", checksum))"
    }

    private func setFailure(stage: String, error: Error) {
        failureStage = stage
        connectionState = .failed("\(stage)：\(error.localizedDescription)")
    }

    private func saveDiagnostics() {
        let stateDescription: String
        switch connectionState {
        case .stopped: stateDescription = "stopped"
        case .scanning: stateDescription = "scanning"
        case .ready: stateDescription = "ready"
        case .connecting: stateDescription = "connecting"
        case .connected: stateDescription = "connected"
        case .failed(let message): stateDescription = "failed: \(message)"
        }
        let body = """
        NMEA Pad diagnostics
        generated: \(Date().ISO8601Format())
        app: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"))
        state: \(stateDescription)
        stage: \(failureStage.isEmpty ? "none" : failureStage)

        === IORegistry ===
        \(registrySummary)

        === libusb ===
        \(libusbLog)
        """
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        do {
            try body.write(to: directory.appendingPathComponent("NMEAPad-Diagnostics.txt"), atomically: true, encoding: .utf8)
            diagnosticsSavedAt = Date()
        } catch {
            // Diagnostics must never replace the primary USB error.
        }
    }
}
