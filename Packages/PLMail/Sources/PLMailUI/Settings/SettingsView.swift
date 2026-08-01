#if os(iOS)

public import PLMailCore

import SwiftUI

/// Settings.
///
/// One screen with one job each below it, rather than the single flat list
/// this used to be — which mixed the server's address, the identities it
/// serves and a destructive sign-out button into the same scroll, and had
/// nowhere to put anything that was not about the server.
///
/// The grouping is by *whose* setting it is, which is the distinction that
/// matters on a self-hosted app: the server's mailboxes and addresses are
/// changed on the server and only shown here, while appearance and image
/// blocking are this device's alone and are the only things this screen can
/// actually change. Mixing the two is what makes people go looking for an Add
/// Account button that cannot exist.
public struct SettingsView: View {
    let connection: ServerConnection
    let sync: MailSyncService
    let store: SyncStore
    let onSignOut: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingSignOut = false
    @State private var appearance = AppearancePreference.shared

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
                Section {
                    NavigationLink {
                        AccountsView(connection: connection, sync: sync, store: store)
                    } label: {
                        // The server is the heading, and the mailbox count is
                        // the thing people come here to check. Both on the row
                        // rather than a bare "Accounts", so the common case —
                        // "is my work mail still connected?" — is answered
                        // without a tap.
                        LabeledContent {
                            Text(accountCount)
                        } label: {
                            Label(.ui("Accounts"), systemImage: "person.crop.circle")
                        }
                    }

                    NavigationLink {
                        IdentitiesView(sync: sync, store: store)
                    } label: {
                        Label(.ui("Sending addresses"), systemImage: "at")
                    }
                } header: {
                    Text(.ui("Mail"))
                }

                Section {
                    NavigationLink {
                        AppearanceView(preference: appearance)
                    } label: {
                        LabeledContent {
                            Text(appearance.choice.title)
                        } label: {
                            Label(.ui("Appearance"), systemImage: "circle.lefthalf.filled")
                        }
                    }

                    NavigationLink {
                        RemoteImagesView()
                    } label: {
                        Label(.ui("Remote images"), systemImage: "photo")
                    }
                } header: {
                    Text(.ui("This device"))
                }

                Section {
                    NavigationLink {
                        ServerDiagnosticsView(
                            connection: connection, sync: sync, store: store)
                    } label: {
                        LabeledContent {
                            // The one place a summary earns its space: a
                            // failing account is exactly what this screen is
                            // for, and burying it one tap down means it is
                            // found by people who already suspected.
                            if sync.degradedAccounts.isEmpty == false {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(ActionTint.spam)
                            }
                        } label: {
                            Label(.ui("Diagnostics"), systemImage: "stethoscope")
                        }
                    }
                } footer: {
                    Text(
                        .ui(
                            "Last sync, sync cursors and your server's limits. Worth a look before filing a bug."
                        ))
                }

                Section {
                    Button(.ui("Sign out"), role: .destructive) {
                        isConfirmingSignOut = true
                    }
                } footer: {
                    Text(.ui("Removes the app password from this device and deletes cached mail."))
                }
            }
            .navigationTitle(Text(.ui("Settings")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Done")) { dismiss() }
                }
            }
            // Confirmed rather than immediate. It used to fire on the first
            // tap, and it throws away a credential that can only be replaced
            // by walking to a browser and issuing a new app password.
            .confirmationDialog(
                .ui("Sign out of \(connection.host)?"),
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button(.ui("Sign out"), role: .destructive) {
                    onSignOut()
                    dismiss()
                }
                Button(.ui("Cancel"), role: .cancel) {}
            } message: {
                Text(
                    .ui(
                        "Mail on this device is deleted. Nothing on your server changes, and you can pair again with a new app password."
                    ))
            }
        }
    }

    private var accountCount: String {
        sync.accounts.count.formatted()
    }
}

#endif
