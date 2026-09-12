import Foundation

public enum FixQuality: Int, Sendable, Codable {
    case invalid = 0, gps = 1, differential = 2, pps = 3, rtkFixed = 4
    case rtkFloat = 5, estimated = 6, manual = 7, simulation = 8

    public var label: String {
        switch self {
        case .invalid: return "無定位"
        case .gps: return "GPS"
        case .differential: return "DGPS"
        case .pps: return "PPS"
        case .rtkFixed: return "RTK Fixed"
        case .rtkFloat: return "RTK Float"
        case .estimated: return "推算"
        case .manual: return "手動"
        case .simulation: return "模擬"
        }
    }
}
public enum Constellation: String, Sendable, Codable, CaseIterable {
    case gps = "GPS", glonass = "GLONASS", galileo = "Galileo"
    case beidou = "BeiDou", qzss = "QZSS", mixed = "GNSS", unknown = "其他"

    static func from(talker: String, prn: Int) -> Constellation {
        switch talker {
        case "GP": return (193...202).contains(prn) ? .qzss : .gps
        case "GL": return .glonass
        case "GA": return .galileo
        case "GB", "BD": return .beidou
        case "GQ": return .qzss
        case "GN":
            switch prn {
            case 1...32: return .gps
            case 65...96: return .glonass
            case 193...202: return .qzss
            case 201...237: return .beidou
            case 301...336: return .galileo
            default: return .mixed
            }
        default: return .unknown
        }
    }
}

public struct Satellite: Identifiable, Sendable, Equatable {
    public var constellation: Constellation
    public var prn: Int
    public var elevation: Int?
    public var azimuth: Int?
    public var snr: Int?
    public var isUsed: Bool
    public var id: String { "\(constellation.rawValue)-\(prn)" }

    public init(constellation: Constellation, prn: Int, elevation: Int?, azimuth: Int?, snr: Int?, isUsed: Bool = false) {
        self.constellation = constellation
        self.prn = prn
        self.elevation = elevation
        self.azimuth = azimuth
        self.snr = snr
        self.isUsed = isUsed
    }
}

public struct RawSentence: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let text: String
    public let type: String
    public let checksumValid: Bool
    public let receivedAt: Date
}

public struct NMEASnapshot: Sendable, Equatable {
    public var latitude: Double?
    public var longitude: Double?
    public var altitudeMeters: Double?
    public var geoidSeparationMeters: Double?
    public var speedKnots: Double?
    public var courseDegrees: Double?
    public var utcDate: Date?
    public var fixQuality: FixQuality = .invalid
    public var fixDimension: Int = 1
    public var satellitesInUse: Int = 0
    public var satellitesInView: Int = 0
    public var hdop: Double?
    public var vdop: Double?
    public var pdop: Double?
    public var differentialAgeSeconds: Double?
    public var stationID: String?
    public var satellites: [Satellite] = []
    public var lastSentenceAt: Date?
    public var validSentenceCount = 0
    public var invalidSentenceCount = 0

    public init() {}
    public var speedKilometersPerHour: Double? { speedKnots.map { $0 * 1.852 } }
    public var hasPosition: Bool { latitude != nil && longitude != nil }
}
