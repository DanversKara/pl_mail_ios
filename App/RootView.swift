import PLMailCore
import PLMailUI
import SwiftUI

/// The app shell: onboarding until there is a connection, mail after.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let connection = model.connection, let sync = model.sync {
                MailView(
                    connection: connection,
                    sync: sync,
                    store: model.store,
                    onSignOut: model.signOut
                )
            } else if model.hasLoaded {
                ServerSetupView { model.signedIn($0) }
            } else {
                ProgressView()
            }
        }
        .modelContainer(model.container)
        .task { model.load() }
    }
}
