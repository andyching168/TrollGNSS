import XCTest
@testable import NMEACore

final class NMEAParserTests: XCTestCase {
    func testGGAParsesTaipeiFix() {
        var parser = NMEAParser()
        let raw = parser.ingest("$GPGGA,092750.000,2502.5186,N,12133.2367,E,1,08,0.9,12.3,M,18.0,M,,*60")
        XCTAssertTrue(raw.checksumValid)
        XCTAssertEqual(parser.snapshot.latitude!, 25.0419767, accuracy: 0.000001)
        XCTAssertEqual(parser.snapshot.longitude!, 121.553945, accuracy: 0.000001)
        XCTAssertEqual(parser.snapshot.altitudeMeters, 12.3)
        XCTAssertEqual(parser.snapshot.fixQuality, .gps)
        XCTAssertEqual(parser.snapshot.satellitesInUse, 8)
    }

    func testInvalidChecksumDoesNotMutateFix() {
        var parser = NMEAParser()
        let raw = parser.ingest("$GPGGA,000000,2500.000,N,12100.000,E,1,03,2.0,1.0,M,0.0,M,,*00")
        XCTAssertFalse(raw.checksumValid)
        XCTAssertNil(parser.snapshot.latitude)
        XCTAssertEqual(parser.snapshot.invalidSentenceCount, 1)
    }

    func testFramerHandlesSplitAndNoise() {
        var framer = NMEAByteFramer()
        XCTAssertTrue(framer.append(Data("noise$GPRMC,1".utf8)).isEmpty)
        XCTAssertEqual(framer.append(Data(",2*00\r\n$GPVTG,3*00\n".utf8)), ["$GPRMC,1,2*00", "$GPVTG,3*00"])
    }

    func testGSVTracksSatellitesAndResetsCount() {
        var parser = NMEAParser()
        parser.ingest(sentence("GPGSV,1,1,02,02,62,045,42,05,48,133,38"))
        XCTAssertEqual(parser.snapshot.satellitesInView, 2)
        XCTAssertEqual(parser.snapshot.satellites.count, 2)
        parser.ingest(sentence("GPGSV,1,1,01,12,35,250,31"))
        XCTAssertEqual(parser.snapshot.satellitesInView, 1)
        XCTAssertEqual(parser.snapshot.satellites.map(\.prn), [12])
    }

    func testRMCParsesSpeedCourseAndUTCDate() {
        var parser = NMEAParser()
        parser.ingest(sentence("GPRMC,092751.00,A,2502.5186,N,12133.2367,E,3.25,42.5,120926,,,A"))
        XCTAssertEqual(parser.snapshot.speedKnots, 3.25)
        XCTAssertEqual(parser.snapshot.courseDegrees, 42.5)
        XCTAssertNotNil(parser.snapshot.utcDate)
    }

    private func sentence(_ payload: String) -> String {
        let checksum = payload.utf8.reduce(UInt8(0), ^)
        return "$\(payload)*\(String(format: "%02X", checksum))"
    }
}
