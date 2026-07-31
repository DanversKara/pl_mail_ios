#if os(iOS)

public import PLMailCore

import SwiftUI

/// What the app knows about the server.
///
/// Kept as a real screen rather than debug scaffolding: plMail users
/// administer the machine they are talking to, so when something is wrong
/// they are the ones who can fix it. Last sync per account, the current
/// error, and the limits actually in force are worth more here than in an
/// app whose backend someone else operates.
public struct ServerDiagnosticsView: View {
    let connection: ServerConnection
    let sync: MailSyncService
    let store: SyncStore
    let onSignOut: () -> Void

    @Environment(\.dismiss) private var dismiss

    public init(
        connection: ServerConnection,
        sync: MailSyncService,
        store: SyncStore,
        onSignOut: @escaping () -> Void
    ) {
        self.connection = connection
        self.sync = sync
        self.store = store
        self.onSignOut = onSignOut
    }

    public var body: some View {
        NavigationStack {
            List {
                Section(.ui("Server")) {
                    LabeledContent(.ui("Address"), value: connection.host)
                    LabeledContent(.ui("Signed in as"), value: connection.username ?? "—")

                    if connection.pinnedFingerprint != nil {
                        Label(.ui("Certificate pinned"), systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if connection.address.isCleartext {
                        Label(.ui("Unencrypted connection"), systemImage: "lock.open")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    NavigationLink {
                        IdentitiesView(sync: sync, store: store)
                    } label: {
                        Label(.ui("Sending addresses"), systemImage: "at")
                    }
                }

                Section(.ui("Mail accounts")) {
                    ForEach(sync.accounts) { account in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)

                            if let failure = sync.degradedAccounts[account.accountKey] {
                                Text(failure)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                Section {
                    Button(.ui("Sign out"), role: .destructive) {
                        onSignOut()
                        dismiss()
                    }
                } footer: {
                    Text(.ui("Removes the app password from this device and deletes cached mail."))
                }
            }
            .navigationTitle(.ui("Server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Done")) { dismiss() }
                }
            }
        }
    }
}

#endif
