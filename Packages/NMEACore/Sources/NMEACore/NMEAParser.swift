import Foundation

public struct NMEAParser: Sendable {
    public private(set) var snapshot = NMEASnapshot()
    private var satellitesByID: [String: Satellite] = [:]
    private var satellitesInViewByTalker: [String: Int] = [:]
    private var usedPRNs: Set<Int> = []
    private var lastDateComponents: DateComponents?

    public init() {}

    @discardableResult
    public mutating func ingest(_ input: String, receivedAt: Date = Date()) -> RawSentence {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Self.fields(from: text)
        let type = parsed?.identifier.suffix(3).uppercased() ?? "???"
        let valid = parsed?.checksumValid == true
        let raw = RawSentence(text: text, type: type, checksumValid: valid, receivedAt: receivedAt)
        snapshot.lastSentenceAt = receivedAt
        guard let parsed, parsed.checksumValid else {
            snapshot.invalidSentenceCount += 1
            return raw
        }
        snapshot.validSentenceCount += 1
        let talker = String(parsed.identifier.prefix(2)).uppercased()
        switch type {
        case "GGA": parseGGA(parsed.values)
        case "RMC": parseRMC(parsed.values)
        case "GSA": parseGSA(parsed.values)
        case "GSV": parseGSV(parsed.values, talker: talker)
        case "VTG": parseVTG(parsed.values)
        case "ZDA": parseZDA(parsed.values)
        case "GLL": parseGLL(parsed.values)
        default: break
        }
        return raw
    }

    private mutating func parseGGA(_ f: [String]) {
        guard f.count >= 14 else { return }
        updatePosition(lat: f[1], ns: f[2], lon: f[3], ew: f[4])
        snapshot.fixQuality = FixQuality(rawValue: Int(f[5]) ?? 0) ?? .invalid
        snapshot.satellitesInUse = Int(f[6]) ?? snapshot.satellitesInUse
        snapshot.hdop = Double(f[7]) ?? snapshot.hdop
        snapshot.altitudeMeters = Double(f[8]) ?? snapshot.altitudeMeters
        snapshot.geoidSeparationMeters = Double(f[10]) ?? snapshot.geoidSeparationMeters
        snapshot.differentialAgeSeconds = Double(f[12])
        snapshot.stationID = f[13].isEmpty ? nil : f[13]
        updateTime(f[0])
    }

    private mutating func parseRMC(_ f: [String]) {
        guard f.count >= 9 else { return }
        if f[1].uppercased() == "A" {
            updatePosition(lat: f[2], ns: f[3], lon: f[4], ew: f[5])
        }
        snapshot.speedKnots = Double(f[6]) ?? snapshot.speedKnots
        snapshot.courseDegrees = Double(f[7]) ?? snapshot.courseDegrees
        if f[8].count == 6 {
            let day = Int(f[8].prefix(2)), month = Int(f[8].dropFirst(2).prefix(2)), yy = Int(f[8].suffix(2))
            if let day, let month, let yy {
                lastDateComponents = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0), year: yy >= 80 ? 1900 + yy : 2000 + yy, month: month, day: day)
            }
        }
        updateTime(f[0])
    }

    private mutating func parseGSA(_ f: [String]) {
        guard f.count >= 17 else { return }
        snapshot.fixDimension = Int(f[1]) ?? snapshot.fixDimension
        usedPRNs = Set(f[2...13].compactMap(Int.init))
        snapshot.pdop = Double(f[14]) ?? snapshot.pdop
        snapshot.hdop = Double(f[15]) ?? snapshot.hdop
        snapshot.vdop = Double(f[16]) ?? snapshot.vdop
        refreshUsedFlags()
    }

    private mutating func parseGSV(_ f: [String], talker: String) {
        guard f.count >= 3 else { return }
        let message = Int(f[1]) ?? 1
        satellitesInViewByTalker[talker] = Int(f[2]) ?? 0
        snapshot.satellitesInView = satellitesInViewByTalker.values.reduce(0, +)
        let constellation = Constellation.from(talker: talker, prn: 0)
        if message == 1 {
            if talker == "GN" {
                satellitesByID.removeAll()
            } else {
                satellitesByID = satellitesByID.filter { $0.value.constellation != constellation }
            }
        }
        var index = 3
        while index + 3 < f.count {
            guard let prn = Int(f[index]) else { index += 4; continue }
            let actualConstellation = Constellation.from(talker: talker, prn: prn)
            let satellite = Satellite(constellation: actualConstellation,
                                      prn: prn,
                                      elevation: Int(f[index + 1]),
                                      azimuth: Int(f[index + 2]),
                                      snr: Int(f[index + 3]),
                                      isUsed: usedPRNs.contains(prn))
            satellitesByID[satellite.id] = satellite
            index += 4
        }
        snapshot.satellites = satellitesByID.values.sorted { ($0.constellation.rawValue, $0.prn) < ($1.constellation.rawValue, $1.prn) }
    }

    private mutating func parseVTG(_ f: [String]) {
        if !f.isEmpty { snapshot.courseDegrees = Double(f[0]) ?? snapshot.courseDegrees }
        if f.count > 4 { snapshot.speedKnots = Double(f[4]) ?? snapshot.speedKnots }
        if f.count > 6, let kmh = Double(f[6]) { snapshot.speedKnots = kmh / 1.852 }
    }

    private mutating func parseZDA(_ f: [String]) {
        guard f.count >= 4, let day = Int(f[1]), let month = Int(f[2]), let year = Int(f[3]) else { return }
        lastDateComponents = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0), year: year, month: month, day: day)
        updateTime(f[0])
    }

    private mutating func parseGLL(_ f: [String]) {
        guard f.count >= 6, f[5].uppercased() == "A" else { return }
        updatePosition(lat: f[0], ns: f[1], lon: f[2], ew: f[3])
        updateTime(f[4])
    }

    private mutating func updatePosition(lat: String, ns: String, lon: String, ew: String) {
        if let value = Self.coordinate(lat, hemisphere: ns) { snapshot.latitude = value }
        if let value = Self.coordinate(lon, hemisphere: ew) { snapshot.longitude = value }
    }

    private mutating func updateTime(_ value: String) {
        guard value.count >= 6, var components = lastDateComponents else { return }
        components.hour = Int(value.prefix(2))
        components.minute = Int(value.dropFirst(2).prefix(2))
        components.second = Int(Double(String(value.dropFirst(4))) ?? 0)
        snapshot.utcDate = components.date
    }

    private mutating func refreshUsedFlags() {
        for key in satellitesByID.keys {
            guard var satellite = satellitesByID[key] else { continue }
            satellite.isUsed = usedPRNs.contains(satellite.prn)
            satellitesByID[key] = satellite
        }
        snapshot.satellites = satellitesByID.values.sorted { ($0.constellation.rawValue, $0.prn) < ($1.constellation.rawValue, $1.prn) }
    }

    static func coordinate(_ value: String, hemisphere: String) -> Double? {
        guard let raw = Double(value) else { return nil }
        let degrees = floor(raw / 100)
        var result = degrees + (raw - degrees * 100) / 60
        if hemisphere.uppercased() == "S" || hemisphere.uppercased() == "W" { result = -result }
        return result
    }

    private static func fields(from sentence: String) -> (identifier: String, values: [String], checksumValid: Bool)? {
        guard sentence.first == "$", let star = sentence.lastIndex(of: "*") else { return nil }
        let payload = String(sentence[sentence.index(after: sentence.startIndex)..<star])
        let supplied = String(sentence[sentence.index(after: star)...]).prefix(2)
        guard let expected = UInt8(supplied, radix: 16) else { return nil }
        let checksum = payload.utf8.reduce(UInt8(0), ^)
        let parts = payload.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let identifier = parts.first, identifier.count >= 5 else { return nil }
        return (identifier, Array(parts.dropFirst()), checksum == expected)
    }
}

public struct NMEAByteFramer: Sendable {
    private var buffer: [UInt8] = []
    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        buffer.append(contentsOf: data)
        if buffer.count > 65_536 { buffer.removeFirst(buffer.count - 65_536) }
        var result: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Array(buffer[..<newline])
            buffer.removeFirst(newline + 1)
            if line.last == 0x0D { line.removeLast() }
            if let start = line.lastIndex(of: 0x24) { line = Array(line[start...]) }
            if let text = String(bytes: line, encoding: .ascii), !text.isEmpty { result.append(text) }
        }
        return result
    }
}
