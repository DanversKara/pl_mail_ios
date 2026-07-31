import PLMailUI
import SwiftUI

@main
struct PLMailApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = _model.wrappedValue
        BackgroundRefresh.register { await model.refreshInBackground() }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await model.scenePhaseChanged(to: phase) }
        }
    }
}
