import Foundation
import USBHostKit
import Darwin

protocol GPSByteConnection: Sendable {
    func read() async throws -> Data
    func close() async
}

actor NativeSerialConnection: GPSByteConnection {
    private var fd: Int32

    init(path: String, baudRate: Int) throws {
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw USBSerialOpenError(stage: "open(O_RDWR) errno=\(errno)", underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
        var config = termios()
        guard tcgetattr(descriptor, &config) == 0 else {
            let code = errno; Darwin.close(descriptor)
            throw USBSerialOpenError(stage: "tcgetattr errno=\(code)", underlying: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
        }
        cfmakeraw(&config)
        config.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard cfsetspeed(&config, speed_t(baudRate)) == 0 else {
            let code = errno; Darwin.close(descriptor)
            throw USBSerialOpenError(stage: "cfsetspeed errno=\(code)", underlying: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
        }
        if tcsetattr(descriptor, TCSANOW, &config) != 0 {
            let code = errno
            // iPadOS permits opening this CDC node but may deny changing its
            // termios. Preserve the driver's existing settings in that case.
            if code != EPERM {
                Darwin.close(descriptor)
                throw USBSerialOpenError(stage: "tcsetattr errno=\(code)", underlying: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
            }
        }
        fd = descriptor
    }

    func read() async throws -> Data {
        while !Task.isCancelled {
            guard fd >= 0 else { throw USBHostError.disconnected }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { throw USBHostError.disconnected }
            if errno != EAGAIN && errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw USBHostError.cancelled
    }

    func close() async {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}

struct USBSerialOpenError: LocalizedError {
    let stage: String
    let underlying: Error

    var errorDescription: String? { "\(stage)：\(underlying.localizedDescription)" }
}

enum USBSerialChipset: String, Sendable {
    case cdcACM = "CDC-ACM"
    case ftdi = "FTDI"
    case cp210x = "CP210x"
    case generic = "Generic Bulk"
}

struct SerialCandidate: Identifiable, Sendable {
    let device: USBProbeDevice
    let chipset: USBSerialChipset
    let dataInterface: UInt8
    let controlInterface: UInt8?
    let inputEndpoint: UInt8
    let outputEndpoint: UInt8?
    let maxPacketSize: UInt16

    var id: String { "\(device.id)-\(dataInterface)" }
    var title: String {
        String(format: "%04X:%04X", device.descriptor.vendorID, device.descriptor.productID)
    }
    var detail: String { "\(chipset.rawValue) · USB \(device.busNumber).\(device.deviceAddress) · IF \(dataInterface)" }
}

enum SerialDetector {
    static func candidates(in devices: [USBProbeDevice]) -> [SerialCandidate] {
        devices.compactMap(candidate)
    }

    private static func candidate(_ device: USBProbeDevice) -> SerialCandidate? {
        let vendor = device.descriptor.vendorID
        let chipset: USBSerialChipset
        if vendor == 0x0403 { chipset = .ftdi }
        else if vendor == 0x10C4 { chipset = .cp210x }
        else if device.interfaces.contains(where: { $0.interface.interfaceClass == 0x02 || $0.interface.interfaceClass == 0x0A }) { chipset = .cdcACM }
        else { chipset = .generic }

        let preferred = device.interfaces.filter { interface in
            interface.endpoints.contains { $0.isInput && ($0.attributes & 0x03) == 2 }
        }.sorted { lhs, rhs in
            let l = lhs.interface.interfaceClass == 0x0A ? 0 : 1
            let r = rhs.interface.interfaceClass == 0x0A ? 0 : 1
            return l < r
        }
        guard let data = preferred.first,
              let input = data.endpoints.first(where: { $0.isInput && ($0.attributes & 0x03) == 2 }) else { return nil }
        let output = data.endpoints.first { !$0.isInput && ($0.attributes & 0x03) == 2 }
        let control = device.interfaces.first { $0.interface.interfaceClass == 0x02 }?.interface.interfaceNumber
        return SerialCandidate(device: device,
                               chipset: chipset,
                               dataInterface: data.interface.interfaceNumber,
                               controlInterface: control,
                               inputEndpoint: input.endpointAddress,
                               outputEndpoint: output?.endpointAddress,
                               maxPacketSize: max(input.maxPacketSize, 8))
    }
}

final class USBSerialConnection: GPSByteConnection, @unchecked Sendable {
    private let session: USBDeviceSession
    let candidate: SerialCandidate

    init(session: USBDeviceSession, candidate: SerialCandidate) {
        self.session = session
        self.candidate = candidate
    }

    func open(baudRate: Int) async throws {
        do {
            try await session.setAutoDetachKernelDriver(true)
        } catch {
            throw USBSerialOpenError(stage: L("stage.enable_detach"), underlying: error)
        }
        if let control = candidate.controlInterface, control != candidate.dataInterface {
            do {
                try await session.claimInterface(control)
            } catch {
                throw USBSerialOpenError(stage: L("stage.claim_cdc", Int(control)), underlying: error)
            }
        }
        var dataClaimed = false
        do {
            do {
                try await session.claimInterface(candidate.dataInterface)
                dataClaimed = true
            } catch {
                throw USBSerialOpenError(stage: L("stage.claim_data", Int(candidate.dataInterface)), underlying: error)
            }
            do {
                try await configure(baudRate: baudRate)
            } catch {
                throw USBSerialOpenError(stage: L("stage.configure_serial", candidate.chipset.rawValue, baudRate), underlying: error)
            }
        } catch {
            if dataClaimed {
                try? await session.releaseInterface(candidate.dataInterface)
            }
            if let control = candidate.controlInterface, control != candidate.dataInterface {
                try? await session.releaseInterface(control)
            }
            throw error
        }
    }

    func read() async throws -> Data {
        let result = try await session.bulkReadDetailed(endpoint: candidate.inputEndpoint,
                                                        length: max(Int(candidate.maxPacketSize) * 8, 512),
                                                        timeoutMilliseconds: 1_000)
        switch candidate.chipset {
        case .ftdi: return stripFTDIStatus(result.data, packetSize: Int(candidate.maxPacketSize))
        default: return result.data
        }
    }

    func close() async {
        try? await session.releaseInterface(candidate.dataInterface)
        if let control = candidate.controlInterface, control != candidate.dataInterface {
            try? await session.releaseInterface(control)
        }
        await session.close()
    }

    private func configure(baudRate: Int) async throws {
        switch candidate.chipset {
        case .cdcACM:
            let index = UInt16(candidate.controlInterface ?? candidate.dataInterface)
            var baud = UInt32(baudRate).littleEndian
            var line = withUnsafeBytes(of: &baud) { Data($0) }
            line.append(contentsOf: [0, 0, 8]) // one stop bit, no parity, 8 data bits
            _ = try await session.controlTransfer(requestType: 0x21, request: 0x20, value: 0,
                                                  index: index, buffer: line, timeoutMilliseconds: 1_000)
            _ = try await session.controlTransfer(requestType: 0x21, request: 0x22, value: 0x0003,
                                                  index: index, buffer: Data(), timeoutMilliseconds: 1_000)
        case .ftdi:
            _ = try await session.controlTransfer(requestType: 0x40, request: 0, value: 0, index: 0,
                                                  buffer: Data(), timeoutMilliseconds: 1_000)
            let divisor = ftdiDivisor(baudRate)
            _ = try await session.controlTransfer(requestType: 0x40, request: 3, value: divisor.value, index: divisor.index,
                                                  buffer: Data(), timeoutMilliseconds: 1_000)
            _ = try await session.controlTransfer(requestType: 0x40, request: 4, value: 8, index: 0,
                                                  buffer: Data(), timeoutMilliseconds: 1_000)
            _ = try await session.controlTransfer(requestType: 0x40, request: 1, value: 0x0303, index: 0,
                                                  buffer: Data(), timeoutMilliseconds: 1_000)
        case .cp210x:
            let index = UInt16(candidate.dataInterface)
            _ = try await session.controlTransfer(requestType: 0x41, request: 0x00, value: 0x0001, index: index,
                                                  buffer: Data(), timeoutMilliseconds: 1_000)
            var baud = UInt32(baudRate).littleEndian
            let baudData = withUnsafeBytes(of: &baud) { Data($0) }
            _ = try await session.controlTransfer(requestType: 0x41, request: 0x1E, value: 0, index: index,
                                                  buffer: baudData, timeoutMilliseconds: 1_000)
            _ = try await session.controlTransfer(requestType: 0x41, request: 0x03, value: 0x0800, index: index,
                                                  buffer: Data(), timeoutMilliseconds: 1_000)
            _ = try await session.controlTransfer(requestType: 0x41, request: 0x07, value: 0x0303, index: index,
                                                  buffer: Data(), timeoutMilliseconds: 1_000)
        case .generic:
            break
        }
    }

    private func ftdiDivisor(_ baudRate: Int) -> (value: UInt16, index: UInt16) {
        let divisor8 = max(8, Int((24_000_000.0 / Double(max(baudRate, 1))).rounded()))
        let fractionCodes = [0, 3, 2, 4, 1, 5, 6, 7]
        let integer = min(divisor8 / 8, 0x3FFF)
        let encoded = integer | (fractionCodes[divisor8 & 7] << 14)
        return (UInt16(encoded & 0xFFFF), UInt16((encoded >> 16) & 0xFFFF))
    }

    private func stripFTDIStatus(_ data: Data, packetSize: Int) -> Data {
        guard data.count > 2, packetSize > 2 else { return Data() }
        var output = Data()
        var offset = 0
        while offset < data.count {
            let end = min(offset + packetSize, data.count)
            if end - offset > 2 { output.append(data[(offset + 2)..<end]) }
            offset = end
        }
        return output
    }
}
