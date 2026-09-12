import SwiftUI

struct SystemLocationView: View {
    @EnvironmentObject private var model: GPSAppModel
    @ObservedObject var injector: SystemLocationInjector
    var body: some View {
        Form {
            Section("系統定位輸出 • 實驗功能") {
                Toggle("系統定位輸出", isOn: Binding(get: { injector.enabled }, set: { injector.setEnabled($0) }))
                LabeledContent(L("外接 GNSS"), value: model.connectionState == .connected ? L("已連線") : L("未連線"))
                LabeledContent("GNSS Fix", value: "\(model.snapshot.fixQuality.localizedLabel) / \(model.snapshot.fixDimension)D")
                LabeledContent("系統注入", value: injector.status)
                LabeledContent("輸入頻率（5 秒）", value: String(format: "%.1f Hz", injector.inputRate))
                LabeledContent("送出頻率（5 秒）", value: String(format: "%.1f Hz", injector.updateRate))
                LabeledContent("最後送出", value: injector.lastSubmission.map { Self.time.string(from: $0) } ?? "—")
                LabeledContent("GNSS → 呼叫完成", value: injector.latency.map { String(format: "%.1f ms", $0) } ?? "—")
                Stepper(L("injector.uere", injector.uereMeters), value: $injector.uereMeters, in: 1...20, step: 0.5)
                Text("水平精度估算 = HDOP × UERE；不是接收器實測精度。無有效 fix 或斷流 3 秒即停止輸出。")
                if !injector.errorMessage.isEmpty { Text(injector.errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                Button("緊急停止並清空系統模擬位置", role: .destructive) { injector.stop() }
            }
            Section("CoreLocation 觀察（本 App，非獨立驗證）") {
                Text(injector.observedLocation).textSelection(.enabled)
                Text("private API 沒有成功回覆；送出頻率不代表其他 App 收到的頻率。背景持續讀取、鎖屏與 crash 清理尚待實機驗證，請勿用於正式導航。")
            }
        }.navigationTitle("系統定位")
    }
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
}
