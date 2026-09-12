import Foundation

public struct ExternalGNSSFix: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let horizontalAccuracy: Double?
    public let verticalAccuracy: Double?
    public let speed: Double? // m/s
    public let course: Double? // degrees
    public let timestamp: Date
}

/// Output-only safety adapter. Does not change the existing parser or display snapshot.
/// RMC defines a new epoch; GGA/GSA supply recent validity and optional metadata.
public struct ExternalFixAdapter {
    public var uereMeters: Double = 5
    public var maximumAge: TimeInterval = 3
    private var gga: (at: Date, quality: Int, altitude: Double?, hdop: Double?)?
    private var gsa: (at: Date, dimension: Int, vdop: Double?)?
    private var lastEpoch: Date?
    public private(set) var unavailableReason: String? = "waiting_rmc_gga"
    public init() {}

    public mutating func consume(_ raw: RawSentence, snapshot: NMEASnapshot, now: Date) -> ExternalGNSSFix? {
        guard raw.checksumValid else { return nil }
        let payload = raw.text.dropFirst().split(separator: "*", omittingEmptySubsequences: false)[0]
        let f = payload.split(separator: ",", omittingEmptySubsequences: false).dropFirst().map(String.init)
        if raw.type == "GGA" {
            guard f.count >= 14 else { unavailableReason = "gga_incomplete"; return nil }
            gga = (now, Int(f[5]) ?? 0, f[9] == "M" ? finite(f[8]) : nil, positive(f[7]))
            if gga?.quality == 0 { unavailableReason = "gga_no_fix" }
            return nil
        }
        if raw.type == "GSA" {
            guard f.count >= 17 else { return nil }
            gsa = (now, Int(f[1]) ?? 1, positive(f[16]))
            if gsa?.dimension == 1 { unavailableReason = "gsa_no_fix" }
            return nil
        }
        guard raw.type == "RMC" else { return nil }
        guard f.count >= 9, f[1] == "A", !(f.count > 11 && ["N", "S", "M", "E"].contains(f[11])) else {
            unavailableReason = "rmc_invalid"; return nil
        }
        guard let gga, now.timeIntervalSince(gga.at) <= maximumAge,
              (1...5).contains(gga.quality) else {
            unavailableReason = "gga_stale_or_invalid"; return nil
        }
        if let gsa, now.timeIntervalSince(gsa.at) <= maximumAge, gsa.dimension < 2 {
            unavailableReason = "gsa_no_fix"; return nil
        }
        guard let lat = coordinate(f[2], f[3], latitude: true),
              let lon = coordinate(f[4], f[5], latitude: false),
              let date = snapshot.utcDate, f[0].count >= 6,
              let seconds = finite(String(f[0].dropFirst(4))), seconds >= 0, seconds < 60 else {
            unavailableReason = "rmc_position_or_utc_invalid"; return nil
        }
        // Existing parser supplies the RMC calendar date and whole seconds. Preserve fractions here.
        let timestamp = date.addingTimeInterval(seconds - floor(seconds))
        guard now.timeIntervalSince(timestamp) <= maximumAge, timestamp.timeIntervalSince(now) <= 1 else {
            unavailableReason = "gnss_utc_out_of_range"; return nil
        }
        guard lastEpoch.map({ timestamp > $0 }) ?? true else { return nil }
        lastEpoch = timestamp
        unavailableReason = nil
        let recentGSA = gsa.flatMap { now.timeIntervalSince($0.at) <= maximumAge ? $0 : nil }
        let altitude = recentGSA?.dimension == 2 ? nil : gga.altitude
        let uere = uereMeters.isFinite && uereMeters > 0 ? uereMeters : 5
        return ExternalGNSSFix(latitude: lat, longitude: lon, altitude: altitude,
            horizontalAccuracy: gga.hdop.map { $0 * uere },
            verticalAccuracy: altitude == nil ? nil : recentGSA?.vdop.map { $0 * uere },
            speed: finite(f[6]).flatMap { $0 >= 0 ? $0 * 0.5144444444444445 : nil },
            course: finite(f[7]).flatMap { (0..<360).contains($0) ? $0 : nil }, timestamp: timestamp)
    }

    private func finite(_ text: String) -> Double? { Double(text).flatMap { $0.isFinite ? $0 : nil } }
    private func positive(_ text: String) -> Double? { finite(text).flatMap { $0 > 0 ? $0 : nil } }
    private func coordinate(_ text: String, _ hemisphere: String, latitude: Bool) -> Double? {
        guard (latitude ? ["N", "S"] : ["E", "W"]).contains(hemisphere),
              let raw = finite(text), raw >= 0, raw.truncatingRemainder(dividingBy: 100) < 60 else { return nil }
        let value = floor(raw / 100) + raw.truncatingRemainder(dividingBy: 100) / 60
        guard value <= (latitude ? 90 : 180) else { return nil }
        return ["S", "W"].contains(hemisphere) ? -value : value
    }
}
