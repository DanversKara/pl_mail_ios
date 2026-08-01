#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// Labels, not folders.
///
/// The unified section comes first because multi-account is the normal
/// case, not the edge case: the default view is everything at once, and
/// picking a single account's mailbox is the narrowing action.
///
/// System roles keep the web UI's fixed order — Inbox, Sent, Drafts, Spam,
/// Trash, Archive — so the two clients don't disagree about where things
/// are. Custom labels sort alphabetically after.
public struct MailboxSidebarView: View {
    let sync: MailSyncService
    let outbox: OutboxSender
    @Binding var selection: FeedID?
    @State private var showingOutbox = false
    /// Unsubscribed labels are hidden until asked for. plMail creates Archive
    /// unsubscribed, so "hidden" here means "not on the sidebar by default",
    /// never "empty" — the mail is real and has to be reachable.
    @State private var showsHiddenLabels = false
    @State private var expandedAccounts: Set<String> = []

    public init(
        sync: MailSyncService, outbox: OutboxSender, selection: Binding<FeedID?>
    ) {
        self.sync = sync
        self.outbox = outbox
        _selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(unifiedRoles, id: \.self) { role in
                    Label {
                        Text(role.displayName)
                    } icon: {
                        Image(systemName: role.symbolName)
                            .foregroundStyle(Self.tint(for: role))
                    }
                    .badge(unreadCount(for: role))
                    .tag(FeedID.unified(role))
                    .listRowBackground(Color.clear)
                }
            }

            // Only when there is something in it. A permanent Outbox row is
            // a permanent suggestion that mail might be stuck, and on a
            // working connection the queue is empty microseconds after a
            // send.
            if outbox.pendingCount > 0 {
                Section {
                    Button {
                        showingOutbox = true
                    } label: {
                        Label {
                            Text(.ui("Outbox"))
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "tray.and.arrow.up.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .badge(outbox.pendingCount)
                    .listRowBackground(Color.clear)
                }
            }

            if labels.isEmpty == false {
                Section(.ui("Labels")) {
                    ForEach(labels, id: \.id) { label in
                        Label {
                            Text(label.name)
                        } icon: {
                            // Hashed from the label id, so a label keeps its
                            // colour when it is renamed — the same rule the
                            // avatars follow, for the same reason.
                            Image(systemName: "tag.fill")
                                .foregroundStyle(
                                    AvatarPalette.color(for: label.labelID.rawValue))
                        }
                        .tag(FeedID.unifiedLabel(label.labelID))
                        .listRowBackground(Color.clear)
                    }
                }
            }

            if sync.accounts.count > 1 {
                Section(.ui("Accounts")) {
                    ForEach(sync.accounts) { account in
                        accountGroup(for: account)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingOutbox) {
            OutboxView(outbox: outbox)
        }
    }

    /// One account, and the mailboxes inside it.
    ///
    /// Collapsed by default. The unified rows at the top are what most people
    /// use; this section exists for the times you want *this* account's Sent,
    /// and opening every account by default would push those unified rows off
    /// a phone screen entirely.
    @ViewBuilder
    private func accountGroup(for account: AccountSnapshot) -> some View {
        let isExpanded = Binding(
            get: { expandedAccounts.contains(account.accountKey) },
            set: { open in
                if open {
                    expandedAccounts.insert(account.accountKey)
                } else {
                    expandedAccounts.remove(account.accountKey)
                }
            })

        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(mailboxes(for: account), id: \.id) { mailbox in
                Label {
                    Text(mailbox.name)
                } icon: {
                    Image(systemName: mailbox.role?.symbolName ?? "tag.fill")
                        .foregroundStyle(
                            Self.tint(for: mailbox.role)
                                ?? AvatarPalette.color(for: mailbox.mailboxID.rawValue))
                }
                .badge(mailbox.unreadThreads)
                .tag(FeedID.mailbox(accountKey: account.accountKey, mailboxID: mailbox.mailboxID))
                .listRowBackground(Color.clear)
            }

            if hiddenMailboxCount(for: account) > 0 {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showsHiddenLabels.toggle() }
                } label: {
                    Label(
                        showsHiddenLabels ? .ui("Hide extra labels") : .ui("Show all labels"),
                        systemImage: showsHiddenLabels ? "eye.slash" : "eye"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
        } label: {
            HStack(spacing: 10) {
                SenderAvatar(
                    name: account.displayName, address: account.displayName, diameter: 24)

                Text(account.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.clear)
    }

    /// This account's mailboxes, in the server's own order.
    ///
    /// Roles first in the fixed order the web UI uses, so the two clients do
    /// not disagree about where Sent lives, then custom labels alphabetically.
    private func mailboxes(for account: AccountSnapshot) -> [MailboxSnapshot] {
        let mine = sync.mailboxes.filter {
            $0.accountKey == account.accountKey && (showsHiddenLabels || $0.isSubscribed)
        }

        let order: [MailboxRole] = [
            .inbox, .flagged, .snoozed, .drafts, .sent, .archive, .junk, .trash,
        ]

        return mine.sorted { first, second in
            switch (
                first.role.flatMap { order.firstIndex(of: $0) },
                second.role.flatMap { order.firstIndex(of: $0) }
            )
            {
            case (let a?, let b?): return a < b
            // A role always outranks a custom label, whichever way round.
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
        }
    }

    private func hiddenMailboxCount(for account: AccountSnapshot) -> Int {
        sync.mailboxes.filter { $0.accountKey == account.accountKey && $0.isSubscribed == false }
            .count
    }

    /// Colour carries the role, so the icons are distinguishable before the
    /// words are read. These follow the platform's own conventions — trash is
    /// never green, spam is never blue — rather than the app's accent, which
    /// would make every row identical.
    /// Nil for a custom label, which has no role and takes a hashed colour
    /// instead. Shared with the reader's chips so one label is one colour
    /// wherever it appears.
    static func tint(for role: MailboxRole?) -> Color? {
        switch role {
        case .none: nil
        case .inbox: .accentColor
        case .flagged: .orange
        case .drafts: .gray
        case .sent: .teal
        case .archive: .green
        case .snoozed: .indigo
        case .junk: .yellow
        case .trash: .red
        default: .secondary
        }
    }

    private static func tint(for role: MailboxRole) -> Color {
        tint(for: Optional(role)) ?? .secondary
    }

    // MARK: - Contents

    /// Only roles that actually exist somewhere. An account with no
    /// Archive binding — the default, since plMail creates it hidden —
    /// should not put an empty row in everyone's sidebar.
    private var unifiedRoles: [MailboxRole] {
        let present = Set(sync.mailboxes.compactMap(\.role))

        return [.inbox, .flagged, .snoozed, .drafts, .sent, .archive, .junk, .trash]
            .filter(present.contains)
    }

    /// Custom labels, collapsed across accounts by their user-scoped label
    /// id. That id is exactly why the server extension exists: matching on
    /// name instead would split "Work" in two the moment it was renamed in
    /// one account.
    private var labels: [LabelRow] {
        var byLabel: [LabelID: LabelRow] = [:]

        for mailbox in sync.mailboxes {
            guard mailbox.role == nil, let labelID = mailbox.labelID else { continue }

            byLabel[labelID, default: LabelRow(labelID: labelID, name: mailbox.name)]
                .accountCount += 1
        }

        return byLabel.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func unreadCount(for role: MailboxRole) -> Int {
        sync.mailboxes
            .filter { $0.role == role }
            .reduce(0) { $0 + $1.unreadThreads }
    }

    struct LabelRow: Identifiable {
        let labelID: LabelID
        let name: String
        var accountCount = 0

        var id: LabelID { labelID }
    }
}

#endif
