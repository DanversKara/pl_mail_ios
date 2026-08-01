#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI
import UIKit

/// What the app knows about the server, in the detail someone who administers
/// it needs.
///
/// Kept as a real screen rather than debug scaffolding: plMail users run the
/// machine they are talking to, so when something is wrong they are the ones
/// who can fix it. That changes what belongs here. In an app whose backend
/// someone else operates, a state token is noise; here it is the difference
/// between "the app is broken" and "that one IMAP account stopped answering at
/// 04:12, and the cursor has not moved since".
///
/// The limits are read from the live Session rather than restated as
/// constants. They are per-server and configurable, and a screen that printed
/// this app's assumptions instead of the server's answers would be at its most
/// confidently wrong exactly when someone came here to find out why an upload
/// failed.
struct ServerDiagnosticsView: View {
    let connection: ServerConnection
    let sync: MailSyncService
    let store: SyncStore

    @State private var session: Session?
    @State private var sessionFailure: String?
    @State private var accounts: [AccountSnapshot] = []
    @State private var didCopy = false

    var body: some View {
        List {
            connectionSection
            accountsSection
            limitsSection
            pushSection
            reportSection
        }
        .navigationTitle(Text(.ui("Diagnostics")))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            LabeledContent(.ui("Address"), value: connection.host)
            LabeledContent(.ui("Signed in as"), value: connection.username ?? "—")
            LabeledContent(.ui("Status")) { statusText }

            if let lastCheckedAt = sync.lastCheckedAt {
                LabeledContent(.ui("Last checked")) {
                    Text(lastCheckedAt, format: .relative(presentation: .named))
                }
            }

            if connection.pinnedFingerprint != nil {
                Label(.ui("Certificate pinned"), systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if connection.address.isCleartext {
                Label(.ui("Unencrypted connection"), systemImage: "lock.open")
                    .font(.footnote)
                    .foregroundStyle(ActionTint.spam)
            }
        } header: {
            Text(.ui("Connection"))
        }
    }

    @ViewBuilder
    private var accountsSection: some View {
        ForEach(displayedAccounts) { account in
            Section {
                if let message = sync.degradedAccounts[account.accountKey]
                    ?? account.lastSyncError
                {
                    Label {
                        Text(verbatim: message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(ActionTint.spam)
                }

                LabeledContent(.ui("Last sync")) {
                    if let lastSyncedAt = account.lastSyncedAt {
                        Text(lastSyncedAt, format: .relative(presentation: .named))
                    } else {
                        Text(.ui("Never"))
                    }
                }

                LabeledContent(.ui("Account id"), value: account.accountID.rawValue)

                // The three cursors, named after the JMAP object each belongs
                // to. A stale one here against a moving one on the server is
                // the whole diagnosis for "new mail never arrives".
                stateRow(.ui("Messages"), token: account.emailState)
                stateRow(.ui("Conversations"), token: account.threadState)
                stateRow(.ui("Labels"), token: account.mailboxState)
            } header: {
                Text(verbatim: account.displayName)
            }
        }
    }

    @ViewBuilder
    private var limitsSection: some View {
        Section {
            if let core = session?.capabilities.core {
                LabeledContent(.ui("Largest attachment")) {
                    Text(Int64(core.maxSizeUpload).formatted(.byteCount(style: .file)))
                }
                LabeledContent(.ui("Largest request")) {
                    Text(Int64(core.maxSizeRequestObject).formatted(.byteCount(style: .file)))
                }
                LabeledContent(.ui("Objects per read"), value: core.maxObjectsInGet.formatted())
                LabeledContent(.ui("Objects per write"), value: core.maxObjectsInSet.formatted())
                LabeledContent(.ui("Calls per request"), value: core.maxCallsInRequest.formatted())
                LabeledContent(
                    .ui("Requests at once"), value: core.maxConcurrentRequests.formatted())
            } else if let sessionFailure {
                Label {
                    Text(verbatim: sessionFailure)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(ActionTint.spam)
            } else {
                ProgressView()
            }
        } header: {
            Text(.ui("Server limits"))
        } footer: {
            Text(
                .ui(
                    "Your server's own numbers, not the app's. A message with a bigger attachment than this is refused before it is sent, and bulk actions are split to fit."
                ))
        }
    }

    @ViewBuilder
    private var pushSection: some View {
        if let session {
            Section {
                if let apns = session.capabilities.apns {
                    Label(.ui("This server can send push notifications"), systemImage: "bell.badge")
                        .font(.footnote)

                    if let environment = apns.environment {
                        LabeledContent(.ui("Environment"), value: environment)
                    }
                    if let topic = apns.topic {
                        LabeledContent(.ui("Topic"), value: topic)
                    }
                } else {
                    // The normal case, and it must read as normal. Sending to
                    // APNs needs a paid Apple developer key, which almost no
                    // self-hoster has; the app polls instead and says so.
                    Label(.ui("No push from this server"), systemImage: "bell.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(.ui("Notifications"))
            } footer: {
                if session.capabilities.apns == nil {
                    Text(
                        .ui(
                            "Sending push notifications to an iPhone needs an Apple developer key on the server. Without one, mail arrives when the app checks — on opening it, and in the background when iOS allows."
                        ))
                }
            }
        }
    }

    private var reportSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = report()
                didCopy = true
            } label: {
                Label(
                    didCopy ? .ui("Copied") : .ui("Copy diagnostics"),
                    systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
        } footer: {
            Text(
                .ui(
                    "Everything on this screen as plain text, for pasting into a bug report. It contains your server's address and your mailbox names, and never your app password."
                ))
        }
    }

    // MARK: - Pieces

    /// Monospaced and truncated in the middle: a state token is an opaque
    /// string that is compared, not read, so the ends are what identify it and
    /// a proportional font makes two similar ones look identical.
    private func stateRow(_ label: LocalizedStringResource, token: StateToken?) -> some View {
        LabeledContent(label) {
            Text(verbatim: token?.rawValue ?? "—")
                .font(.footnote.monospaced())
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var displayedAccounts: [AccountSnapshot] {
        accounts.isEmpty ? sync.accounts : accounts
    }

    private var statusText: Text {
        switch sync.status {
        case .idle: Text(.ui("Connected"))
        case .syncing: Text(.ui("Checking…"))
        case .unauthenticated: Text(.ui("App password rejected"))
        case .failed(let message): Text(verbatim: message)
        }
    }

    // MARK: - Loading

    private func reload() async {
        accounts = (try? await store.accounts()) ?? []

        do {
            session = try await sync.jmapClient.session()
            sessionFailure = nil
        } catch {
            session = nil
            sessionFailure = String(describing: error)
        }
    }

    /// The report is deliberately **not** localised.
    ///
    /// It exists to be pasted into an issue or a forum post that whoever reads
    /// it will be reading in English, and a German traceback helps nobody
    /// debug it. The screen above is the localised one; this is the artefact.
    private func report() -> String {
        var lines: [String] = ["plMail for iOS diagnostics"]

        lines.append("server: \(connection.host)")
        lines.append("user: \(connection.username ?? "unknown")")
        lines.append("pinned: \(connection.pinnedFingerprint == nil ? "no" : "yes")")
        lines.append("cleartext: \(connection.address.isCleartext ? "yes" : "no")")
        lines.append("status: \(sync.status)")
        lines.append("lastChecked: \(sync.lastCheckedAt.map(isoFormatted) ?? "never")")

        for account in displayedAccounts {
            lines.append("")
            lines.append("account \(account.accountID.rawValue): \(account.displayName)")
            lines.append("  readOnly: \(account.isReadOnly)")
            lines.append("  lastSynced: \(account.lastSyncedAt.map(isoFormatted) ?? "never")")
            lines.append(
                "  error: \(sync.degradedAccounts[account.accountKey] ?? account.lastSyncError ?? "none")"
            )
            lines.append("  emailState: \(account.emailState?.rawValue ?? "—")")
            lines.append("  threadState: \(account.threadState?.rawValue ?? "—")")
            lines.append("  mailboxState: \(account.mailboxState?.rawValue ?? "—")")
        }

        if let core = session?.capabilities.core {
            lines.append("")
            lines.append("limits")
            lines.append("  maxSizeUpload: \(core.maxSizeUpload)")
            lines.append("  maxSizeRequestObject: \(core.maxSizeRequestObject)")
            lines.append("  maxObjectsInGet: \(core.maxObjectsInGet)")
            lines.append("  maxObjectsInSet: \(core.maxObjectsInSet)")
            lines.append("  maxCallsInRequest: \(core.maxCallsInRequest)")
            lines.append("  maxConcurrentRequests: \(core.maxConcurrentRequests)")
            lines.append("  maxConcurrentUpload: \(core.maxConcurrentUpload)")
        }

        if let session {
            lines.append("")
            lines.append("apns: \(session.capabilities.apns == nil ? "not advertised" : "yes")")
            lines.append(
                "webPush: \(session.capabilities.push?.isConfigured == true ? "configured" : "no")")
        }

        if let sessionFailure {
            lines.append("")
            lines.append("sessionError: \(sessionFailure)")
        }

        return lines.joined(separator: "\n")
    }

    private func isoFormatted(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

#endif
