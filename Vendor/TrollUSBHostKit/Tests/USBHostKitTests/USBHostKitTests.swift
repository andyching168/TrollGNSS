import XCTest
import CUSBShim
@testable import USBHostKit

final class USBHostErrorMapperTests: XCTestCase {
    func testAccessMapsToPermission() {
        XCTAssertEqual(USBHostErrorMapper.error(from: Int32(UHS_ERROR_ACCESS.rawValue)), .permission)
    }

    func testNoDeviceAndNotFoundMapToDisconnected() {
        XCTAssertEqual(USBHostErrorMapper.error(from: Int32(UHS_ERROR_NO_DEVICE.rawValue)), .disconnected)
        XCTAssertEqual(USBHostErrorMapper.error(from: Int32(UHS_ERROR_NOT_FOUND.rawValue)), .disconnected)
    }

    func testBusyMapsToInterfaceUnavailable() {
        XCTAssertEqual(USBHostErrorMapper.error(from: Int32(UHS_ERROR_BUSY.rawValue)), .interfaceUnavailable)
    }

    func testTimeoutMapsToTimeout() {
        XCTAssertEqual(USBHostErrorMapper.error(from: Int32(UHS_ERROR_TIMEOUT.rawValue)), .timeout)
    }

    func testInterruptedMapsToCancelled() {
        XCTAssertEqual(USBHostErrorMapper.error(from: Int32(UHS_ERROR_INTERRUPTED.rawValue)), .cancelled)
    }

    func testUnknownCodeMapsToUnknown() {
        XCTAssertEqual(USBHostErrorMapper.error(from: 1234), .unknown)
    }
}

final class USBEndpointDescriptorTests: XCTestCase {
    func testDirectionAndNumber() {
        let input = USBEndpointDescriptor(endpointAddress: 0x81, attributes: 2, maxPacketSize: 512, interval: 0)
        XCTAssertTrue(input.isInput)
        XCTAssertEqual(input.endpointNumber, 1)

        let output = USBEndpointDescriptor(endpointAddress: 0x02, attributes: 2, maxPacketSize: 512, interval: 0)
        XCTAssertFalse(output.isInput)
        XCTAssertEqual(output.endpointNumber, 2)
    }
}

final class USBProbeInterfaceTests: XCTestCase {
    private func makeInterface(class: UInt8, subclass: UInt8, protocol: UInt8) -> USBProbeInterface {
        let interface = USBInterfaceDescriptor(interfaceNumber: 0,
                                               alternateSetting: 0,
                                               numberOfEndpoints: 2,
                                               interfaceClass: `class`,
                                               interfaceSubclass: subclass,
                                               interfaceProtocol: `protocol`,
                                               interfaceIndex: 0)
        return USBProbeInterface(interface: interface, endpoints: [])
    }

    func testADBClassTupleIsDetected() {
        XCTAssertTrue(makeInterface(class: 0xFF, subclass: 0x42, protocol: 0x01).isADBInterface)
    }

    func testNonADBInterfaceIsNotDetected() {
        XCTAssertFalse(makeInterface(class: 0xFF, subclass: 0x42, protocol: 0x00).isADBInterface)
        XCTAssertFalse(makeInterface(class: 0x08, subclass: 0x06, protocol: 0x50).isADBInterface)
    }

    func testADBInterfacesFilter() {
        let adb = makeInterface(class: 0xFF, subclass: 0x42, protocol: 0x01)
        let other = makeInterface(class: 0x08, subclass: 0x06, protocol: 0x50)
        let device = USBProbeDevice(busNumber: 1,
                                    deviceAddress: 2,
                                    descriptor: makeDescriptor(),
                                    speed: .high,
                                    interfaces: [adb, other])
        XCTAssertEqual(device.adbInterfaces, [adb])
        XCTAssertEqual(device.id, "1.2")
    }
}

final class USBSpeedTests: XCTestCase {
    func testMapping() {
        XCTAssertEqual(USBSpeed.from(UHS_SPEED_LOW), .low)
        XCTAssertEqual(USBSpeed.from(UHS_SPEED_FULL), .full)
        XCTAssertEqual(USBSpeed.from(UHS_SPEED_HIGH), .high)
        XCTAssertEqual(USBSpeed.from(UHS_SPEED_SUPER), .superSpeed)
        XCTAssertEqual(USBSpeed.from(UHS_SPEED_SUPER_PLUS), .superSpeedPlus)
        XCTAssertEqual(USBSpeed.from(UHS_SPEED_UNKNOWN), .unknown)
    }
}

// MARK: - Session lifetime, cancellation, detach (fake backend)

/// Fake backend session that records operations and lets tests drive transfer
/// completion exactly like the event-loop thread would.
final class FakeBackendSession: USBBackendSession, @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private var claimed: [UInt8] = []
    private var nextToken: UInt = 1
    private var pending: [UInt: (Result<USBTransferResult, USBHostError>) -> Void] = [:]
    private(set) var cancelledTokens: [UInt] = []
    private(set) var closeCount = 0
    private(set) var resetCount = 0
    var resetError: USBHostError?

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    var pendingTokens: [UInt] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pending.keys)
    }

    func setAutoDetachKernelDriver(_ enabled: Bool) throws {
        guard isOpen else { throw USBHostError.disconnected }
    }

    func claim(interface: UInt8) throws {
        lock.lock()
        defer { lock.unlock() }
        guard open else { throw USBHostError.disconnected }
        claimed.append(interface)
    }

    func release(interface: UInt8) throws {
        lock.lock()
        defer { lock.unlock() }
        guard open else { throw USBHostError.disconnected }
        claimed.removeAll { $0 == interface }
    }

    func resetDevice() throws {
        lock.lock()
        defer { lock.unlock() }
        guard open else { throw USBHostError.disconnected }
        if let resetError {
            throw resetError
        }
        resetCount += 1
    }

    func close() {
        lock.lock()
        guard open else {
            lock.unlock()
            return
        }
        closeCount += 1
        open = false
        let completions = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        // Simulate libusb terminating in-flight transfers on teardown.
        for completion in completions {
            completion(.failure(.disconnected))
        }
    }

    func controlTransfer(requestType: UInt8,
                         request: UInt8,
                         value: UInt16,
                         index: UInt16,
                         buffer: Data,
                         timeoutMilliseconds: UInt32) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard open else { throw USBHostError.disconnected }
        return Data(repeating: 0xAB, count: buffer.count)
    }

    func stringDescriptor(index: UInt8) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard open else { throw USBHostError.disconnected }
        return "FakeDevice"
    }

    func submitBulkRead(endpoint: UInt8,
                        length: Int,
                        timeoutMilliseconds: UInt32,
                        completion: @escaping (Result<USBTransferResult, USBHostError>) -> Void) throws -> UInt {
        lock.lock()
        defer { lock.unlock() }
        guard open else { throw USBHostError.disconnected }
        let token = nextToken
        nextToken += 1
        pending[token] = completion
        return token
    }

    func submitBulkWrite(endpoint: UInt8,
                         data: Data,
                         timeoutMilliseconds: UInt32,
                         completion: @escaping (Result<USBTransferResult, USBHostError>) -> Void) throws -> UInt {
        lock.lock()
        defer { lock.unlock() }
        guard open else { throw USBHostError.disconnected }
        let token = nextToken
        nextToken += 1
        pending[token] = completion
        return token
    }

    func cancelTransfer(_ token: UInt) {
        lock.lock()
        cancelledTokens.append(token)
        let completion = pending.removeValue(forKey: token)
        lock.unlock()
        completion?(.failure(.cancelled))
    }

    /// Test helper: completes a pending transfer like the event-loop thread.
    func completeTransfer(_ token: UInt, with result: Result<Data, USBHostError>) {
        lock.lock()
        let completion = pending.removeValue(forKey: token)
        lock.unlock()
        completion?(result.map { data in
            USBTransferResult(data: data,
                              recoveredFromTimeout: false,
                              nativeStatus: "ok",
                              nativeTransferred: data.count)
        })
    }

    /// Test helper: simulates a timed-out read that still delivered bytes
    /// (native actual_length > 0), i.e. the recoveredFromTimeout path.
    func completeTransferAsTimeout(_ token: UInt, with data: Data) {
        lock.lock()
        let completion = pending.removeValue(forKey: token)
        lock.unlock()
        completion?(.success(USBTransferResult(data: data,
                                               recoveredFromTimeout: true,
                                               nativeStatus: "timeout",
                                               nativeTransferred: data.count)))
    }

    /// Test helper: simulates a cable detach on a pending transfer.
    func detachTransfer(_ token: UInt) {
        completeTransfer(token, with: .failure(.disconnected))
    }
}

final class USBDeviceSessionTests: XCTestCase {
    private func makeSession(_ backend: USBBackendSession = FakeBackendSession()) -> USBDeviceSession {
        USBDeviceSession(backend: backend, executor: USBHostExecutor(label: "USBHostKitTests.executor"))
    }

    private func expectError<Value>(_ expression: @autoclosure () async throws -> Value,
                                    equals expected: USBHostError,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? USBHostError, expected, file: file, line: line)
        }
    }

    func testRepeatedOpenCloseIsSafeAndIdempotent() async {
        let fake = FakeBackendSession()
        let session = makeSession(fake)
        for _ in 0..<3 {
            await session.close()
            await session.close()
        }
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(fake.closeCount, 1) // only the first close actually closes
    }

    func testClosedSessionOperationsThrowDisconnected() async {
        let session = makeSession()
        await session.close()
        await expectError(try await session.claimInterface(0), equals: .disconnected)
        await expectError(try await session.releaseInterface(0), equals: .disconnected)
        await expectError(try await session.bulkRead(endpoint: 0x81, length: 64, timeoutMilliseconds: 100), equals: .disconnected)
        await expectError(try await session.bulkWrite(endpoint: 0x01, data: Data([0x00]), timeoutMilliseconds: 100), equals: .disconnected)
        await expectError(try await session.controlTransfer(requestType: 0x80, request: 0, value: 0, index: 0, buffer: Data(count: 8), timeoutMilliseconds: 100), equals: .disconnected)
        await expectError(try await session.stringDescriptor(index: 1), equals: .disconnected)
    }

    func testClaimAndReleaseRoundTrip() async throws {
        let fake = FakeBackendSession()
        let session = makeSession(fake)
        try await session.claimInterface(0)
        XCTAssertTrue(fake.isOpen)
        try await session.releaseInterface(0)
    }

    func testResetDeviceReachesTheBackend() async throws {
        let fake = FakeBackendSession()
        let session = makeSession(fake)

        try await session.resetDevice()

        XCTAssertEqual(fake.resetCount, 1)
    }

    func testResetDeviceSurfacesBackendFailure() async throws {
        let fake = FakeBackendSession()
        fake.resetError = .permission
        let session = makeSession(fake)

        do {
            try await session.resetDevice()
            XCTFail("Expected the backend failure to surface")
        } catch {
            XCTAssertEqual(error as? USBHostError, .permission)
        }
        XCTAssertEqual(fake.resetCount, 0)
    }

    func testResetDeviceOnClosedSessionThrowsDisconnected() async throws {
        let fake = FakeBackendSession()
        let session = makeSession(fake)
        await session.close()

        do {
            try await session.resetDevice()
            XCTFail("Expected a disconnected error")
        } catch {
            XCTAssertEqual(error as? USBHostError, .disconnected)
        }
    }

    func testBulkReadCompletionReturnsDataExactlyOnce() async throws {
        let fake = FakeBackendSession()
        let session = makeSession(fake)
        let task = Task<Data, Error> {
            try await session.bulkRead(endpoint: 0x81, length: 64, timeoutMilliseconds: 10_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard let token = fake.pendingTokens.first else {
            return XCTFail("transfer was never submitted")
        }
        fake.completeTransfer(token, with: .success(Data([0x01, 0x02, 0x03])))
        let data = try await task.value
        XCTAssertEqual(Array(data), [0x01, 0x02, 0x03])

        // A stale completion must not crash or resume twice.
        fake.completeTransfer(token, with: .success(Data([0xFF])))
        fake.cancelTransfer(token)
    }

    func testBulkReadCancellationResumesExactlyOnce() async {
        let fake = FakeBackendSession()
        let session = makeSession(fake)
        let task = Task<Data, Error> {
            try await session.bulkRead(endpoint: 0x81, length: 64, timeoutMilliseconds: 10_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await expectError(try await task.value, equals: .cancelled)
        XCTAssertFalse(fake.cancelledTokens.isEmpty)

        // Cancelling again is harmless.
        task.cancel()
        fake.cancelTransfer(fake.cancelledTokens.first!)
    }

    func testDetachDuringPendingReadCompletesExactlyOnce() async {
        let fake = FakeBackendSession()
        let session = makeSession(fake)
        let task = Task<Data, Error> {
            try await session.bulkRead(endpoint: 0x81, length: 64, timeoutMilliseconds: 10_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard let token = fake.pendingTokens.first else {
            return XCTFail("transfer was never submitted")
        }
        fake.detachTransfer(token)
        await expectError(try await task.value, equals: .disconnected)

        // A stale completion must not crash or resume twice.
        fake.detachTransfer(token)
        task.cancel()
    }

    func testCloseDuringPendingReadCompletesExactlyOnce() async {
        let fake = FakeBackendSession()
        let session = makeSession(fake)
        let task = Task<Data, Error> {
            try await session.bulkRead(endpoint: 0x81, length: 64, timeoutMilliseconds: 10_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await session.close()
        await expectError(try await task.value, equals: .disconnected)
    }

    func testBulkReadDeliversPartialBytesOnTimeout() async throws {
        let fake = FakeBackendSession()
        let session = makeSession(fake)
        let task = Task<Data, Error> {
            try await session.bulkRead(endpoint: 0x81, length: 64, timeoutMilliseconds: 10_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard let token = fake.pendingTokens.first else {
            return XCTFail("transfer was never submitted")
        }
        // A timed-out read that the kernel still delivered 32768 bytes for
        // (32768 = 64 x 512, an exact maxPacketSize multiple needing a ZLP).
        fake.completeTransferAsTimeout(token, with: Data(repeating: 0xAA, count: 32_768))
        let data = try await task.value
        XCTAssertEqual(data.count, 32_768)
    }

    func testBulkReadDetailedReportsRecoveredTimeout() async throws {
        let fake = FakeBackendSession()
        let session = makeSession(fake)
        let task = Task<USBTransferResult, Error> {
            try await session.bulkReadDetailed(endpoint: 0x81, length: 64, timeoutMilliseconds: 10_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard let token = fake.pendingTokens.first else {
            return XCTFail("transfer was never submitted")
        }
        fake.completeTransferAsTimeout(token, with: Data(count: 16_384))
        let result = try await task.value
        XCTAssertTrue(result.recoveredFromTimeout)
        XCTAssertEqual(result.nativeTransferred, 16_384)
        XCTAssertEqual(result.nativeStatus, "timeout")
        XCTAssertEqual(result.data.count, 16_384)
    }

    func testBulkReadPureTimeoutStillThrows() async {
        let fake = FakeBackendSession()
        let session = makeSession(fake)
        let task = Task<Data, Error> {
            try await session.bulkRead(endpoint: 0x81, length: 64, timeoutMilliseconds: 10_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard let token = fake.pendingTokens.first else {
            return XCTFail("transfer was never submitted")
        }
        fake.completeTransfer(token, with: .failure(.timeout))
        await expectError(try await task.value, equals: .timeout)
    }

    func testBulkWriteRoundTrip() async throws {
        let fake = FakeBackendSession()
        let session = makeSession(fake)
        let task = Task<Void, Error> {
            try await session.bulkWrite(endpoint: 0x01, data: Data([0xDE, 0xAD]), timeoutMilliseconds: 10_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard let token = fake.pendingTokens.first else {
            return XCTFail("write was never submitted")
        }
        fake.completeTransfer(token, with: .success(Data([0xDE, 0xAD])))
        try await task.value
    }
}

// MARK: - Hotplug event stream

final class USBHostControllerTests: XCTestCase {
    func testAttachDetachEventsAreDeliveredInOrder() async {
        let controller = USBHostController()
        let descriptor = makeDescriptor()

        // Emit before any iteration; the stream buffers.
        controller.emit(.attached(descriptor))
        controller.emit(.detached(descriptor))

        var iterator = controller.events.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first, .attached(descriptor))
        XCTAssertEqual(second, .detached(descriptor))
    }
}

// MARK: - Shared helpers

private func makeDescriptor() -> USBDeviceDescriptor {
    USBDeviceDescriptor(usbVersion: 0x0300,
                        deviceClass: 0,
                        deviceSubclass: 0,
                        deviceProtocol: 0,
                        maxPacketSize0: 64,
                        vendorID: 0x2717,
                        productID: 0xFF08,
                        deviceVersion: 0x0100,
                        manufacturerIndex: 1,
                        productIndex: 2,
                        serialNumberIndex: 3,
                        numberOfConfigurations: 1,
                        locationID: 0)
}
