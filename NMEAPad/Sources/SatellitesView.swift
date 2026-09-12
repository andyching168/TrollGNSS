import NMEACore
import SwiftUI

struct SatellitesView: View {
    @EnvironmentObject private var model: GPSAppModel
    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("天空圖").font(.title2.bold())
                    SkyPlot(satellites: model.snapshot.satellites).frame(minHeight: 470)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("衛星訊號").font(.title2.bold()); Spacer(); Text(L("satellites.count", model.snapshot.satellites.count)).foregroundStyle(.secondary) }
                    ForEach(model.snapshot.satellites) { satellite in SatelliteRow(satellite: satellite) }
                    if model.snapshot.satellites.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.secondary)
                            Text("尚無衛星資料").font(.headline)
                            Text("等待 GSV 句子").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(40)
                    }
                }.frame(width: 360)
            }.padding(24)
        }.navigationTitle("衛星")
    }
}

struct SkyPlot: View {
    let satellites: [Satellite]
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                ForEach([1.0, 0.66, 0.33], id: \.self) { scale in Circle().stroke(.white.opacity(0.14), lineWidth: 1).frame(width: size * scale, height: size * scale) }
                Rectangle().fill(.white.opacity(0.12)).frame(width: size, height: 1)
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: size)
                ForEach([("N", 0.0, -0.48), ("E", 0.48, 0.0), ("S", 0.0, 0.48), ("W", -0.48, 0.0)], id: \.0) { item in
                    Text(item.0).font(.caption.bold()).foregroundStyle(.secondary).offset(x: size * item.1, y: size * item.2)
                }
                ForEach(satellites.filter { $0.azimuth != nil && $0.elevation != nil }) { satellite in
                    let radius = (1 - Double(satellite.elevation ?? 0) / 90) * size * 0.45
                    let angle = Double(satellite.azimuth ?? 0) * .pi / 180
                    Text("\(satellite.prn)").font(.caption2.bold()).frame(width: 34, height: 34)
                        .background(color(satellite).gradient, in: Circle()).foregroundStyle(.black)
                        .overlay(Circle().stroke(satellite.isUsed ? .white : .clear, lineWidth: 3))
                        .offset(x: sin(angle) * radius, y: -cos(angle) * radius)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.aspectRatio(1, contentMode: .fit)
    }
    private func color(_ satellite: Satellite) -> Color {
        switch satellite.constellation { case .gps: return .cyan; case .glonass: return .orange; case .galileo: return .green; case .beidou: return .red; case .qzss: return .purple; default: return .gray }
    }
}

struct SatelliteRow: View {
    let satellite: Satellite
    var body: some View {
        HStack(spacing: 12) {
            Text("\(satellite.prn)").font(.system(.body, design: .monospaced).bold()).frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(satellite.constellation.localizedLabel).font(.caption); Spacer(); Text(satellite.snr.map { "\($0) dB" } ?? "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                GeometryReader { proxy in
                    Capsule().fill(.white.opacity(0.08)).overlay(alignment: .leading) { Capsule().fill(signalColor).frame(width: proxy.size.width * min(Double(satellite.snr ?? 0) / 50, 1)) }
                }.frame(height: 7)
            }
            Image(systemName: satellite.isUsed ? "checkmark.circle.fill" : "circle").foregroundStyle(satellite.isUsed ? .green : .secondary)
        }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
    private var signalColor: Color { let snr = satellite.snr ?? 0; return snr >= 35 ? .green : snr >= 20 ? .orange : .red }
}
