import PLMailCore
import PLMailUI
import SwiftUI

/// The app shell: onboarding until there is a connection, mail after.
struct RootView: View {
    @Bindable var model: AppModel

    /// The last `plmail://pair` link this app was opened with.
    ///
    /// Held by the shell rather than by onboarding: the link can arrive while
    /// the app is cold, before that view exists, and dropping it would send the
    /// user back to the server for another code.
    @State private var pairingLink: URL?

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
                ServerSetupView(pairingLink: pairingLink) { model.signedIn($0) }
            } else {
                ProgressView()
            }
        }
        .modelContainer(model.container)
        .task { model.load() }
        .onOpenURL { url in
            // Only while signed out. A pairing link arriving at a device that
            // already has a mailbox would otherwise silently replace it.
            guard model.connection == nil else { return }

            pairingLink = url
        }
    }
}
