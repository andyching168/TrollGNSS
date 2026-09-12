import SwiftUI

@main
struct NMEAPadApp: App {
    @StateObject private var model = GPSAppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .task { await model.start() }
        }
    }
}
