import PLMailCore
import PLMailUI
import SwiftData
import SwiftUI

/// The app shell: onboarding until there is a connection, mail after.
struct RootView: View {
    @State private var connection: ServerConnection?
    @State private var hasLoaded = false

    private let store = CredentialStore()
    private let container = MailStack.makeContainer()

    var body: some View {
        Group {
            if let connection {
                MailView(
                    connection: connection,
                    store: SyncStore(modelContainer: container),
                    onSignOut: signOut
                )
            } else if hasLoaded {
                ServerSetupView { connection = $0 }
            } else {
                ProgressView()
            }
        }
        .modelContainer(container)
        .task {
            guard hasLoaded == false else { return }
            // A malformed keychain entry means onboarding, not a crash: the
            // entry is replaceable and the user can sign in again.
            connection = try? store.load()
            hasLoaded = true
        }
    }

    private func signOut() {
        try? store.delete()

        // The cache belonged to that credential. Leaving it would show the
        // previous account's mail behind the next sign-in screen.
        Task {
            try? await SyncStore(modelContainer: container).deleteEverything()
        }

        connection = nil
    }
}

#Preview {
    RootView()
}
