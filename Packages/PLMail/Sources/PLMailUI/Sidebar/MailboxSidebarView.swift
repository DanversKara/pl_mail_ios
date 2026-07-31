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
    @Binding var selection: FeedID?

    public init(sync: MailSyncService, selection: Binding<FeedID?>) {
        self.sync = sync
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
                        HStack(spacing: 10) {
                            SenderAvatar(
                                name: account.name, address: account.name, diameter: 24)

                            Text(account.name)
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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
