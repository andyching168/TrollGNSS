import CoreLocation
import NMEACore
import UIKit

@MainActor
protocol SystemLocationInjecting {
    func start() throws
    func update(_ fix: ExternalGNSSFix) throws
    func stop()
}

@MainActor
final class SystemLocationInjector: NSObject, ObservableObject, SystemLocationInjecting, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var status = L("injector.off")
    @Published private(set) var errorMessage = ""
    @Published private(set) var inputRate = 0.0
    @Published private(set) var updateRate = 0.0
    @Published private(set) var lastSubmission: Date?
    @Published private(set) var latency: Double?
    @Published private(set) var observedLocation = L("injector.not_observed")
    @Published var uereMeters = 5.0
    private let bridge = LocationSimulationBridge()
    private let observer = CLLocationManager()
    private var adapter = ExternalFixAdapter()
    private var timer: Timer?
    private var inputTimes: [TimeInterval] = []
    private var outputTimes: [TimeInterval] = []
    private var lastInputUptime: TimeInterval?
    private var active = false
    private var lastFix: ExternalGNSSFix?
    private let marker = "NMEAPad.simulationNeedsCleanup"

    override init() {
        super.init()
        observer.delegate = self
        observer.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        observer.distanceFilter = kCLDistanceFilterNone
        observer.pausesLocationUpdatesAutomatically = false
        observer.showsBackgroundLocationIndicator = true
        if UserDefaults.standard.bool(forKey: marker) { stop() }
        NotificationCenter.default.addObserver(self, selector: #selector(terminating), name: UIApplication.willTerminateNotification, object: nil)
    }

    func start() throws {
        guard !enabled else { return }
        try bridge.prepare()
        guard observer.authorizationStatus != .denied && observer.authorizationStatus != .restricted else {
            throw NSError(domain: "NMEAPad.Location", code: 2, userInfo: [NSLocalizedDescriptionKey: L("injector.permission_denied")])
        }
        enabled = true
        adapter = ExternalFixAdapter()
        inputTimes = []; outputTimes = []; lastInputUptime = nil
        status = L("injector.waiting_fix")
        errorMessage = ""
        if observer.authorizationStatus == .notDetermined { observer.requestWhenInUseAuthorization() }
        else { beginObservation() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func setEnabled(_ value: Bool) {
        if !value { stop(); return }
        do { try start() } catch { errorMessage = error.localizedDescription; status = L("injector.cannot_start") }
    }

    func consume(_ raw: RawSentence, snapshot: NMEASnapshot) {
        guard enabled else { return }
        adapter.uereMeters = uereMeters
        let now = Date()
        if let fix = adapter.consume(raw, snapshot: snapshot, now: now) {
            let uptime = ProcessInfo.processInfo.systemUptime
            inputTimes.append(uptime); lastInputUptime = uptime
            do { try update(fix) }
            catch { unavailable(L("injector.call_error")); errorMessage = error.localizedDescription }
        } else if let reason = adapter.unavailableReason { unavailable(L("adapter.\(reason)")) }
    }

    func update(_ fix: ExternalGNSSFix) throws {
        guard enabled else { return }
        guard CLLocationCoordinate2DIsValid(.init(latitude: fix.latitude, longitude: fix.longitude)),
              Date().timeIntervalSince(fix.timestamp) <= 3, fix.timestamp.timeIntervalSinceNow <= 1 else {
            unavailable(L("injector.invalid_fix")); return
        }
        // CLLocation has no optional altitude; -1 verticalAccuracy explicitly invalidates its placeholder.
        let location = CLLocation(coordinate: .init(latitude: fix.latitude, longitude: fix.longitude),
            altitude: fix.altitude ?? 0, horizontalAccuracy: fix.horizontalAccuracy ?? -1,
            verticalAccuracy: fix.altitude == nil ? -1 : (fix.verticalAccuracy ?? -1),
            course: fix.course ?? -1, speed: fix.speed ?? -1, timestamp: fix.timestamp)
        UserDefaults.standard.set(true, forKey: marker)
        active = true // Cleanup also runs after a partially failed transaction.
        try bridge.submit(location)
        lastFix = fix
        lastSubmission = Date()
        latency = Date().timeIntervalSince(fix.timestamp) * 1000
        outputTimes.append(ProcessInfo.processInfo.systemUptime)
        status = L("injector.submitted")
        errorMessage = ""
    }

    func unavailable(_ reason: String) {
        if active {
            do { try bridge.stop(); active = false; UserDefaults.standard.set(false, forKey: marker) }
            catch { errorMessage = "停止 simulation：\(error.localizedDescription)" }
        }
        status = L("injector.paused", reason)
    }

    func stop() {
        enabled = false
        timer?.invalidate(); timer = nil
        observer.stopUpdatingLocation()
        // Explicit OFF is also an emergency reset, even after a previous process crashed.
        do {
            try bridge.stop(); active = false
            UserDefaults.standard.set(false, forKey: marker)
            status = L("injector.cleared")
            errorMessage = ""
        } catch { status = L("injector.stop_failed"); errorMessage = error.localizedDescription }
        inputRate = 0; updateRate = 0
        writeDiagnostics()
    }

    @objc private func terminating() { if enabled || active { stop() } }
    private func beginObservation() {
        guard enabled else { return }
        observer.allowsBackgroundLocationUpdates = true
        observer.startUpdatingLocation()
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) { beginObservation() }
        else if enabled && manager.authorizationStatus != .notDetermined {
            stop(); errorMessage = L("injector.background_permission_denied")
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        observedLocation = String(format: "%.7f, %.7f • simulated=%@ • age=%.2fs", location.coordinate.latitude,
            location.coordinate.longitude, location.sourceInformation?.isSimulatedBySoftware == true ? "yes" : "no",
            Date().timeIntervalSince(location.timestamp))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        observedLocation = L("injector.corelocation_error", error.localizedDescription)
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastInputUptime, now - lastInputUptime > 3 { unavailable(L("injector.no_fix_3s")) }
        if active, let lastFix, Date().timeIntervalSince(lastFix.timestamp) > 3 { unavailable(L("injector.timestamp_stale")) }
        inputTimes.removeAll { now - $0 > 5 }; outputTimes.removeAll { now - $0 > 5 }
        inputRate = Double(inputTimes.count) / 5; updateRate = Double(outputTimes.count) / 5
        writeDiagnostics()
    }
    private func writeDiagnostics() {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let values: [String: Any] = ["generated": Date().ISO8601Format(), "enabled": enabled,
            "status": status, "error": errorMessage, "inputHz5s": inputRate, "submissionHz5s": updateRate,
            "lastSubmissionUnix": lastSubmission?.timeIntervalSince1970 ?? -1, "latencyMs": latency ?? -1,
            "latitude": lastFix?.latitude ?? NSNull(), "longitude": lastFix?.longitude ?? NSNull(),
            "coreLocationObservation": observedLocation, "background": UIApplication.shared.applicationState == .background]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("LocationInjection-Diagnostics.json"), options: .atomic)
        }
    }
}
