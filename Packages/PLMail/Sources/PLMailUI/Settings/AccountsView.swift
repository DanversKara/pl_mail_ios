#if os(iOS)

public import PLMailCore

import SwiftUI

/// The mailboxes this login can see, and where they actually come from.
///
/// Worth stating plainly, because the app looks like it has multi-account
/// settings and does not: **plMail owns the accounts, the app owns one
/// credential.** The IMAP, Gmail and Outlook mailboxes listed here were
/// connected in plMail's web interface and are handed to every client through
/// one JMAP session. There is no JMAP method to connect or disconnect one, so
/// this screen shows them and links out rather than offering an Add button
/// that would have to lie.
///
/// The same fact is why signing out is all-or-nothing: there is one app
/// password in the Keychain covering the lot, and "sign out of just this
/// mailbox" would mean revoking something the app does not hold. Said in the
/// footer rather than left to be discovered by someone who expected otherwise.
struct AccountsView: View {
    let connection: ServerConnection
    let sync: MailSyncService
    let store: SyncStore

    @State private var accounts: [AccountSnapshot] = []
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                ForEach(displayedAccounts) { account in
                    AccountRow(account: account, degradedMessage: degradedMessage(for: account))
                }
            } header: {
                Text(.ui("Mailboxes on this server"))
            } footer: {
                Text(
                    .ui(
                        "These are the mailboxes plMail collects for you. Connecting or disconnecting one is done on the server, not here."
                    ))
            }

            Section {
                Button(.ui("Open plMail in a browser"), systemImage: "safari") {
                    openURL(connection.address.baseURL)
                }
            }

            Section {
                LabeledContent(.ui("Server"), value: connection.host)
                LabeledContent(.ui("Signed in as"), value: connection.username ?? "—")
            } footer: {
                Text(
                    .ui(
                        "One app password covers every mailbox above, so signing out signs out of all of them. To use a different server, sign out and pair again — this app holds one at a time."
                    ))
            }
        }
        .navigationTitle(Text(.ui("Accounts")))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    /// The store's copy is preferred because it carries the last sync time and
    /// the last error; the service's in-memory list is a snapshot taken before
    /// those were written and would show "never synced" straight after a sync.
    private var displayedAccounts: [AccountSnapshot] {
        accounts.isEmpty ? sync.accounts : accounts
    }

    private func degradedMessage(for account: AccountSnapshot) -> String? {
        sync.degradedAccounts[account.accountKey] ?? account.lastSyncError
    }

    private func reload() async {
        accounts = (try? await store.accounts()) ?? []
    }
}

/// One mailbox: what it is called, whether it is current, and what went wrong.
struct AccountRow: View {
    let account: AccountSnapshot
    let degradedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: account.displayName)

            if account.isReadOnly {
                Label(.ui("Read-only"), systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let degradedMessage {
                Label {
                    Text(verbatim: degradedMessage)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(ActionTint.spam)
            } else if let lastSyncedAt = account.lastSyncedAt {
                Text(
                    .ui(
                        "Synced \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                // Not an error, and not dressed as one: a mailbox added on the
                // server a minute ago has legitimately never synced here.
                Text(.ui("Not synced yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#endif
