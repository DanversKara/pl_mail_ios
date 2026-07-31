import PLMailUI
import SwiftUI

@main
struct PLMailApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Only here because the device-token callback is delivered nowhere else.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var push

    init() {
        let model = _model.wrappedValue
        BackgroundRefresh.register { await model.refreshInBackground() }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { model.adopt(push) }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await model.scenePhaseChanged(to: phase) }
        }
    }
}
