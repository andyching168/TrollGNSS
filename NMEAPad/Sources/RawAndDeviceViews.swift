import NMEACore
import SwiftUI

struct RawNMEAView: View {
    @EnvironmentObject private var model: GPSAppModel
    @State private var onlyInvalid = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("nmea.valid", model.snapshot.validSentenceCount)).foregroundStyle(.green)
                Text(L("nmea.invalid", model.snapshot.invalidSentenceCount)).foregroundStyle(.red)
                Spacer()
                Toggle("只看 checksum 錯誤", isOn: $onlyInvalid).toggleStyle(.switch).fixedSize()
            }.font(.subheadline.monospacedDigit()).padding()
            Divider()
            List(filtered) { sentence in
                HStack(alignment: .top, spacing: 12) {
                    Text(sentence.type).font(.caption.bold()).foregroundStyle(sentence.checksumValid ? .cyan : .red).frame(width: 34)
                    Text(sentence.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Text(sentence.receivedAt.formatted(date: .omitted, time: .standard)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.listStyle(.plain)
        }.navigationTitle("NMEA 原始資料")
    }
    private var filtered: [NMEACore.RawSentence] { onlyInvalid ? model.rawSentences.filter { !$0.checksumValid } : model.rawSentences }
}

struct DeviceView: View {
    @EnvironmentObject private var model: GPSAppModel
    @State private var showDiagnostics = false
    var body: some View {
        Form {
            Section("USB Serial GPS") {
                if model.candidates.isEmpty {
                    VStack(spacing: 8) {
                        Label("找不到相容裝置", systemImage: "cable.connector.slash").font(.headline)
                        Text("請接上 GPS，必要時使用有供電的 USB hub。").font(.footnote).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    Picker(L("裝置"), selection: $model.selectedCandidateID) {
                        ForEach(model.candidates) { candidate in Text("\(candidate.title) · \(candidate.chipset.rawValue)").tag(Optional(candidate.id)) }
                    }
                    Picker(L("鮑率"), selection: $model.baudRate) {
                        ForEach(model.supportedBaudRates, id: \.self) { Text("\($0) bps").tag($0) }
                    }
                    if let candidate = model.selectedCandidate {
                        LabeledContent(L("介面"), value: candidate.detail)
                        LabeledContent("Bulk IN", value: String(format: "0x%02X · %d bytes", candidate.inputEndpoint, candidate.maxPacketSize))
                    }
                }
                HStack {
                    Button { Task { await model.scan() } } label: { Label("重新掃描", systemImage: "arrow.clockwise") }
                    Spacer()
                    if model.connectionState == .connected {
                        Button(role: .destructive) { Task { await model.disconnect() } } label: { Text("中斷連線") }
                    } else {
                        Button { Task { await model.connectSelected() } } label: { Text("連線") }.buttonStyle(.borderedProminent).disabled(model.selectedCandidate == nil)
                    }
                }
            }
            Section("定位細節") {
                LabeledContent("PDOP", value: format(model.snapshot.pdop))
                LabeledContent("HDOP", value: format(model.snapshot.hdop))
                LabeledContent("VDOP", value: format(model.snapshot.vdop))
                LabeledContent(L("大地水準面差"), value: model.snapshot.geoidSeparationMeters.map { String(format: "%.1f m", $0) } ?? "—")
                LabeledContent(L("差分站"), value: model.snapshot.stationID ?? "—")
            }
            Section("測試與診斷") {
                Button("載入介面示範資料") { model.loadDemoData() }
                Button("重新啟動 USB Host") { Task { await model.retryUSBHost() } }
                Button("更新 USB 診斷") { Task { await model.refreshDiagnostics(); showDiagnostics = true } }
                if !model.failureStage.isEmpty {
                    LabeledContent(L("失敗階段"), value: model.failureStage)
                }
                if let savedAt = model.diagnosticsSavedAt {
                    LabeledContent(L("診斷檔"), value: L("diagnostics.saved", savedAt.formatted(date: .omitted, time: .standard)))
                }
                if showDiagnostics {
                    DisclosureGroup("IORegistry") { Text(model.registrySummary).font(.caption.monospaced()).textSelection(.enabled) }
                    DisclosureGroup("libusb log") { Text(model.libusbLog).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            Section("相容性") {
                Text("原生設定：CDC-ACM、FTDI、CP210x。其他具有 Bulk IN 的裝置會列為 Generic Bulk；這類裝置必須已由韌體設定為所選鮑率。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("裝置")
    }
    private func format(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "—" }
}
