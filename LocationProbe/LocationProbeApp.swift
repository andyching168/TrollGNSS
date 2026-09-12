import SwiftUI
import CoreLocation

@MainActor
final class ProbeModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var output = NSLocalizedString("probe.instructions", comment: "")
    private let manager = CLLocationManager()
    private var times: [Date] = []
    override init() { super.init(); manager.delegate = self }
    func start() {
        manager.requestWhenInUseAuthorization()
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let received = Date()
        for location in locations {
            times.append(received); times.removeAll { received.timeIntervalSince($0) > 5 }
            let record: [String: Any] = ["receivedUnix": received.timeIntervalSince1970,
                "timestampUnix": location.timestamp.timeIntervalSince1970,
                "latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude,
                "altitude": location.altitude, "horizontalAccuracy": location.horizontalAccuracy,
                "verticalAccuracy": location.verticalAccuracy, "speed": location.speed, "course": location.course,
                "simulated": location.sourceInformation?.isSimulatedBySoftware ?? false,
                "callbackHz5s": Double(times.count) / 5]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8),
               let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                output = text
                try? data.write(to: directory.appendingPathComponent("latest.json"), options: .atomic)
                let url = directory.appendingPathComponent("locations.jsonl")
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                if let handle = try? FileHandle(forWritingTo: url) {
                    do { try handle.seekToEnd(); try handle.write(contentsOf: Data((text + "\n").utf8)); try handle.close() }
                    catch { try? handle.close() }
                }
            }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { output = error.localizedDescription }
}

@main
struct LocationProbeApp: App {
    @StateObject private var model = ProbeModel()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("CoreLocation Probe").font(.largeTitle)
                Button("開始觀察", action: model.start)
                Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("紀錄位於 Documents/locations.jsonl；此測試 App 不提供系統注入。")
            }.padding()
        }
    }
}
