import XCTest
@testable import NMEACore

final class ExternalFixAdapterTests: XCTestCase {
    private let epoch = ISO8601DateFormatter().date(from: "2026-09-12T13:00:00Z")!
    private func feed(_ payload: String, _ parser: inout NMEAParser, _ adapter: inout ExternalFixAdapter, at date: Date) -> ExternalGNSSFix? {
        let checksum = payload.utf8.reduce(UInt8(0), ^)
        let raw = parser.ingest("$\(payload)*\(String(format: "%02X", checksum))", receivedAt: date)
        return adapter.consume(raw, snapshot: parser.snapshot, now: date)
    }
    func testRatesAndFractionalUTC() {
        for hz in [1, 5, 10] {
            var parser = NMEAParser(), adapter = ExternalFixAdapter()
            var count = 0
            for i in 0..<(hz * 2) {
                let seconds = Double(i) / Double(hz)
                let time = String(format: "1300%05.2f", seconds)
                let date = epoch.addingTimeInterval(seconds + 0.1)
                _ = feed("GPGGA,\(time),2502.5186,N,12133.2367,E,1,08,0.9,12.3,M,18.0,M,,", &parser, &adapter, at: date)
                let fix = feed("GPRMC,\(time),A,2502.5186,N,12133.2367,E,10,42.5,120926,,,A", &parser, &adapter, at: date)
                XCTAssertNotNil(fix)
                if let fix {
                    count += 1
                    XCTAssertEqual(fix.timestamp.timeIntervalSince(epoch), seconds, accuracy: 0.0001)
                    XCTAssertEqual(fix.speed!, 5.144444444444445, accuracy: 0.0001)
                    XCTAssertEqual(fix.horizontalAccuracy!, 4.5, accuracy: 0.0001)
                }
                XCTAssertNil(feed("GPRMC,\(time),A,2502.5186,N,12133.2367,E,10,42.5,120926,,,A", &parser, &adapter, at: date))
            }
            XCTAssertEqual(count, hz * 2)
        }
    }
    func testInvalidAndStaleFixNotReplayed() {
        var parser = NMEAParser(), adapter = ExternalFixAdapter()
        _ = feed("GPGGA,130000,2502.5186,N,12133.2367,E,0,00,0.9,12.3,M,18,M,,", &parser, &adapter, at: epoch)
        XCTAssertNil(feed("GPRMC,130000,A,2502.5186,N,12133.2367,E,10,42.5,120926,,,A", &parser, &adapter, at: epoch))
        _ = feed("GPGGA,130000,2502.5186,N,12133.2367,E,1,08,0.9,12.3,M,18,M,,", &parser, &adapter, at: epoch)
        XCTAssertNil(feed("GPRMC,130000,V,2502.5186,N,12133.2367,E,10,42.5,120926,,,A", &parser, &adapter, at: epoch))
        XCTAssertNil(feed("GPRMC,130000,A,2502.5186,N,12133.2367,E,10,42.5,120926,,,A", &parser, &adapter, at: epoch.addingTimeInterval(10)))
    }
    func testUnavailableFieldsAndRecovery() {
        var parser = NMEAParser(), adapter = ExternalFixAdapter()
        _ = feed("GPGGA,130000,2502.5186,N,12133.2367,E,1,08,,,,M,,,", &parser, &adapter, at: epoch)
        let fix = feed("GPRMC,130000,A,2502.5186,N,12133.2367,E,,,120926,,,A", &parser, &adapter, at: epoch)
        XCTAssertNotNil(fix)
        XCTAssertNil(fix?.speed); XCTAssertNil(fix?.course); XCTAssertNil(fix?.altitude); XCTAssertNil(fix?.horizontalAccuracy)
        _ = feed("GPGGA,130001,2502.5186,N,12133.2367,E,0,00,,,,M,,,", &parser, &adapter, at: epoch.addingTimeInterval(1))
        XCTAssertNotNil(adapter.unavailableReason)
        _ = feed("GPGGA,130002,2502.5186,N,12133.2367,E,1,08,1,10,M,18,M,,", &parser, &adapter, at: epoch.addingTimeInterval(2))
        XCTAssertNotNil(feed("GPRMC,130002,A,2502.5186,N,12133.2367,E,0,0,120926,,,A", &parser, &adapter, at: epoch.addingTimeInterval(2)))
    }
}
