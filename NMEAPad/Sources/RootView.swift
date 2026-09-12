import MapKit
import NMEACore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview, satellites, raw, device, systemLocation
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: return L("nav.overview")
        case .satellites: return L("nav.satellites")
        case .raw: return L("nav.nmea")
        case .device: return L("nav.device")
        case .systemLocation: return L("nav.system_location")
        }
    }
    var icon: String {
        switch self {
        case .overview: return "location.north.circle.fill"
        case .satellites: return "dot.radiowaves.left.and.right"
        case .raw: return "text.alignleft"
        case .device: return "cable.connector"
        case .systemLocation: return "location.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: GPSAppModel
    @State private var selection: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationTitle("TrollGNSS")
            .safeAreaInset(edge: .bottom) { ConnectionBadge() }
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView()
                case .satellites: SatellitesView()
                case .raw: RawNMEAView()
                case .device: DeviceView()
                case .systemLocation: SystemLocationView(injector: model.locationInjector)
                }
            }
            .background(Color(red: 0.035, green: 0.055, blue: 0.085).ignoresSafeArea())
        }
        .tint(.cyan)
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject private var model: GPSAppModel
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer()
        }
        .padding(12)
        .background(.thinMaterial)
    }
    private var label: String {
        switch model.connectionState {
        case .stopped: return L("connection.stopped")
        case .scanning: return L("connection.scanning")
        case .ready: return model.candidates.isEmpty ? L("connection.waiting") : L("connection.ready")
        case .connecting: return L("connection.connecting")
        case .connected: return L("connection.connected")
        case .failed(let message): return message
        }
    }
    private var color: Color {
        switch model.connectionState {
        case .connected: return .green
        case .failed: return .red
        case .connecting, .scanning: return .orange
        default: return .secondary
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject private var model: GPSAppModel
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("即時定位").font(.largeTitle.bold())
                        Text(statusText).foregroundStyle(.secondary)
                    }
                    Spacer()
                    FixPill(quality: model.snapshot.fixQuality)
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    MetricCard(title: L("metric.speed"), value: formatted(model.snapshot.speedKilometersPerHour, "%.1f"), unit: "km/h", icon: "speedometer")
                    MetricCard(title: L("metric.altitude"), value: formatted(model.snapshot.altitudeMeters, "%.1f"), unit: "m", icon: "mountain.2.fill")
                    MetricCard(title: L("metric.satellites_used"), value: "\(model.snapshot.satellitesInUse)", unit: L("unit.satellites"), icon: "sparkles")
                    MetricCard(title: "HDOP", value: formatted(model.snapshot.hdop, "%.1f"), unit: accuracyLabel, icon: "scope")
                }
                HStack(alignment: .top, spacing: 14) {
                    CoordinateCard().frame(maxWidth: .infinity)
                    CompassCard(course: model.snapshot.courseDegrees).frame(width: 230)
                }
                if let lat = model.snapshot.latitude, let lon = model.snapshot.longitude {
                    PositionMap(latitude: lat, longitude: lon).frame(height: 310).clipShape(RoundedRectangle(cornerRadius: 20))
                }
            }
            .padding(24)
        }
        .navigationTitle("總覽")
    }

    private var statusText: String {
        guard let date = model.snapshot.lastSentenceAt else { return L("overview.no_nmea") }
        return L("overview.last_data", date.formatted(date: .omitted, time: .standard))
    }
    private var accuracyLabel: String {
        guard let hdop = model.snapshot.hdop else { return "—" }
        if hdop < 1 { return L("accuracy.excellent") }; if hdop < 2 { return L("accuracy.good") }; if hdop < 5 { return L("accuracy.fair") }; return L("accuracy.poor")
    }
    private func formatted(_ value: Double?, _ format: String) -> String { value.map { String(format: format, $0) } ?? "—" }
}

struct MetricCard: View {
    let title: String, value: String, unit: String, icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.cyan)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 34, weight: .bold, design: .rounded))
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct FixPill: View {
    let quality: FixQuality
    var body: some View {
        Text(quality.localizedLabel).font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 7)
            .background(quality == .invalid ? Color.red.opacity(0.2) : Color.green.opacity(0.2), in: Capsule())
            .foregroundStyle(quality == .invalid ? .red : .green)
    }
}

struct CoordinateCard: View {
    @EnvironmentObject private var model: GPSAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("座標").font(.headline)
            coordinate(L("coordinate.latitude"), model.snapshot.latitude, positive: "N", negative: "S")
            coordinate(L("coordinate.longitude"), model.snapshot.longitude, positive: "E", negative: "W")
            Divider()
            HStack {
                datum("UTC", model.snapshot.utcDate?.formatted(date: .abbreviated, time: .standard) ?? "—")
                Spacer()
                datum(L("coordinate.dimension"), model.snapshot.fixDimension >= 3 ? "3D" : model.snapshot.fixDimension == 2 ? "2D" : L("common.none"))
            }
        }
        .padding(20).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }
    private func coordinate(_ title: String, _ value: Double?, positive: String, negative: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(String(format: "%.6f° %@", abs(value), value >= 0 ? positive : negative)).font(.system(.title3, design: .monospaced).weight(.semibold))
            } else { Text("—").font(.title3.bold()) }
        }
    }
    private func datum(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline.weight(.medium)) }
    }
}

struct CompassCard: View {
    let course: Double?
    var body: some View {
        VStack(spacing: 10) {
            Text("航向").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 12)
                ForEach(0..<12) { index in
                    Capsule().fill(index % 3 == 0 ? Color.white : Color.white.opacity(0.35)).frame(width: 2, height: index % 3 == 0 ? 12 : 7).offset(y: -73).rotationEffect(.degrees(Double(index) * 30))
                }
                Image(systemName: "location.north.fill").font(.system(size: 56)).foregroundStyle(.cyan.gradient)
                    .rotationEffect(.degrees(course ?? 0))
                Text(course.map { String(format: "%.0f°", $0) } ?? "—").font(.title3.bold()).offset(y: 53)
            }.frame(width: 175, height: 175)
        }
        .padding(20).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct GPSPin: Identifiable { let id = 1; let coordinate: CLLocationCoordinate2D }

struct PositionMap: View {
    let latitude: Double, longitude: Double
    @State private var region: MKCoordinateRegion
    init(latitude: Double, longitude: Double) {
        self.latitude = latitude; self.longitude = longitude
        _region = State(initialValue: MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)))
    }
    var body: some View {
        Map(coordinateRegion: $region, annotationItems: [GPSPin(coordinate: .init(latitude: latitude, longitude: longitude))]) { pin in
            MapAnnotation(coordinate: pin.coordinate) {
                ZStack { Circle().fill(.cyan.opacity(0.25)).frame(width: 42, height: 42); Circle().fill(.cyan).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3)) }
            }
        }
        .onChange(of: latitude) { _ in recenter() }.onChange(of: longitude) { _ in recenter() }
    }
    private func recenter() { region.center = .init(latitude: latitude, longitude: longitude) }
}
