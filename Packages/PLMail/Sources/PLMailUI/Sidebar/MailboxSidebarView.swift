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
    let labelActions: LabelActions
    /// Only for drops. Optional so a caller that offers no drag and drop still
    /// gets a sidebar: nil turns the drop targets off rather than turning them
    /// into rows that accept a conversation and quietly lose it.
    let actions: MailActions?
    /// The shell's own calendar service, so this view can *read* availability
    /// rather than be told it.
    ///
    /// Passed in rather than constructed: a second `CalendarService` would open
    /// a second `CalendarStore` over the same SQLite file, and two writers to
    /// one store is the failure the single-writer rule exists to prevent.
    /// Optional so a caller with no calendar at all still gets a sidebar.
    let calendar: CalendarService?
    /// Opens the calendar, through whatever route the shell already uses.
    ///
    /// A closure rather than a `FeedID` case: the calendar is not a feed, and
    /// inventing one would put a mail-shaped id in front of a surface that has
    /// no messages in it. It also keeps this row on the shell's **one** path —
    /// the same `isShowingCalendar` the toolbar button and ⌘0 drive — so the
    /// three cannot disagree about what is on screen.
    let openCalendar: (() -> Void)?
    @Binding var selection: FeedID?
    /// Which row a conversation is currently hovering over, so exactly one
    /// lights up. A per-row `@State` flag cannot manage that — SwiftUI does not
    /// promise to tell the row it left before it tells the next one it
    /// arrived, and two highlighted drop targets read as two destinations.
    @State private var dropTarget: DropTarget?
    @State private var showingOutbox = false
    @State private var showingLabelManager = false
    /// Unsubscribed labels are hidden until asked for. plMail creates Archive
    /// unsubscribed, so "hidden" here means "not on the sidebar by default",
    /// never "empty" — the mail is real and has to be reachable.
    @State private var showsHiddenLabels = false
    @State private var expandedAccounts: Set<String> = []

    public init(
        sync: MailSyncService,
        outbox: OutboxSender,
        labelActions: LabelActions,
        actions: MailActions? = nil,
        calendar: CalendarService? = nil,
        openCalendar: (() -> Void)? = nil,
        selection: Binding<FeedID?>
    ) {
        self.sync = sync
        self.outbox = outbox
        self.labelActions = labelActions
        self.actions = actions
        self.calendar = calendar
        self.openCalendar = openCalendar
        _selection = selection
    }

    /// The theme, for the accent the Inbox row carries and the curve the
    /// hidden-labels disclosure animates on.
    @Environment(\.theme) private var theme
    /// One resolved theme serves both appearances, so the palette is chosen
    /// per draw rather than stored.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.standardAnimation) private var standardAnimation

    /// The accent this appearance resolves to, spelled once so the two
    /// `tint(for:accent:)` call sites below cannot drift apart.
    private var accent: Color { theme.accentColor(in: colorScheme) }

    public var body: some View {
        // Built once for the whole sidebar rather than inside either `ForEach`.
        // The walk is per label and the index is per list: constructing it in a
        // row body would rescan every mailbox for every row on every redraw,
        // which is the cost `LabelHierarchy` exists as a value to avoid.
        let hierarchy = LabelHierarchy(sync.mailboxes)

        List(selection: $selection) {
            Section {
                ForEach(unifiedRoles, id: \.self) { role in
                    Label {
                        Text(role.displayName)
                    } icon: {
                        Image(systemName: role.symbolName)
                            .foregroundStyle(Self.tint(for: role, accent: accent))
                    }
                    .badge(unreadCount(for: role))
                    .tag(FeedID.unified(role))
                    .listRowBackground(Color.clear)
                    .dropTarget(.role(role), current: $dropTarget, accept: accept)
                }
            }

            calendarRow

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

            // Shown even with no labels yet, because the row that *makes* one
            // lives here. Hiding the section until a label exists would leave
            // a new account with no way to create its first.
            Section(.ui("Labels")) {
                ForEach(labels(in: hierarchy), id: \.id) { label in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label.name)

                            // The leaf alone makes two labels called `Q1`,
                            // one under Work and one under Personal, into two
                            // identical rows with no way to tell which is
                            // which. Nil for a top-level label, so a flat
                            // account draws nothing extra.
                            if let parents = label.parentPath {
                                Text(parents)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    // Tail truncation would eat the nearest
                                    // ancestor, which is the component that
                                    // actually disambiguates the row.
                                    .truncationMode(.middle)
                            }
                        }
                    } icon: {
                        // The colour the user picked, falling back to the
                        // hashed tint only when none was chosen — so a label
                        // still keeps one colour across a rename, and a
                        // deliberate grey stays grey.
                        Image(systemName: "tag.fill")
                            .foregroundStyle(
                                LabelTint.color(
                                    for: label.color, seed: label.labelID.rawValue))
                    }
                    // Spoken rather than drawn: VoiceOver reads `Work / Q1` as
                    // "Work slash Q1", and the caption would otherwise be read
                    // as a second, separate string.
                    .accessibilityLabel(Text(label.spokenPath))
                    .tag(FeedID.unifiedLabel(label.labelID))
                    .listRowBackground(Color.clear)
                    .dropTarget(
                        .unifiedLabel(labelID: label.labelID, name: label.name),
                        current: $dropTarget, accept: accept)
                }

                Button {
                    showingLabelManager = true
                } label: {
                    Label(
                        hasLabels ? .ui("Edit labels") : .ui("Create a label"),
                        systemImage: hasLabels ? "slider.horizontal.3" : "plus.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }

            if sync.accounts.count > 1 {
                Section(.ui("Accounts")) {
                    ForEach(sync.accounts) { account in
                        accountGroup(for: account, hierarchy: hierarchy)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingOutbox) {
            OutboxView(outbox: outbox)
        }
        .sheet(isPresented: $showingLabelManager) {
            LabelManagerView(sync: sync, labels: labelActions)
        }
    }

    /// The calendar, if this server has one.
    ///
    /// **Absent, not disabled.** A plMail instance without the calendar
    /// extension is a supported instance rather than a broken one, and a
    /// greyed-out row is a promise that something is coming when nothing is.
    ///
    /// It cannot flicker in on launch: `CalendarAvailability.isAvailable`
    /// deliberately starts false and is never optional, so "we do not know yet"
    /// renders exactly as "no" until the probe or the cache says otherwise.
    ///
    /// A `Button` rather than a tagged row, like the Outbox row above it: the
    /// calendar is not a `FeedID`, so there is nothing for `List(selection:)`
    /// to carry, and adding a mail-shaped id for a surface with no messages in
    /// it would be a second way to say what is open. Pressing it goes through
    /// the shell's own route, which is what keeps this row, the toolbar button
    /// and ⌘0 in agreement.
    @ViewBuilder
    private var calendarRow: some View {
        if let openCalendar, calendar?.availability.isAvailable == true {
            Section {
                Button(action: openCalendar) {
                    Label {
                        Text(.ui("Calendar"))
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "calendar")
                            .foregroundStyle(.themeAccent)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    /// One account, and the mailboxes inside it.
    ///
    /// Collapsed by default. The unified rows at the top are what most people
    /// use; this section exists for the times you want *this* account's Sent,
    /// and opening every account by default would push those unified rows off
    /// a phone screen entirely.
    ///
    /// `hierarchy` is built once by ``body`` over every account's mailboxes and
    /// passed in rather than built here, so an eight-account sidebar builds one
    /// index rather than eight.
    @ViewBuilder
    private func accountGroup(
        for account: AccountSnapshot, hierarchy: LabelHierarchy
    ) -> some View {
        let isExpanded = Binding(
            get: { expandedAccounts.contains(account.accountKey) },
            set: { open in
                if open {
                    expandedAccounts.insert(account.accountKey)
                } else {
                    expandedAccounts.remove(account.accountKey)
                }
            })

        // Asked once for the account, not once per row: `hasNesting` scans
        // every mailbox, and inside the `ForEach` that is a full scan per row
        // per redraw for an answer that cannot differ between them.
        let nested = hierarchy.hasNesting

        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(mailboxes(for: account), id: \.id) { mailbox in
                // Nil for a top-level label, and skipped outright for an
                // account with no nesting: a second line under every row in a
                // flat account is noise that says nothing.
                let parents = nested ? hierarchy.parentPath(for: mailbox) : nil

                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mailbox.name)

                        if let parents {
                            Text(parents)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                // The nearest ancestor is the component that
                                // disambiguates, and tail truncation is what
                                // removes it.
                                .truncationMode(.middle)
                        }
                    }
                } icon: {
                    Image(systemName: mailbox.role?.symbolName ?? "tag.fill")
                        .foregroundStyle(
                            // A role keeps its platform colour — trash is never
                            // green. Only a custom label reaches the chosen
                            // colour, and only an uncoloured one the hash.
                            Self.tint(for: mailbox.role, accent: accent)
                                ?? LabelTint.color(
                                    for: mailbox.color,
                                    seed: mailbox.labelID?.rawValue ?? mailbox.name))
                }
                .accessibilityLabel(Text(spokenName(of: mailbox, in: hierarchy, nested: nested)))
                .badge(mailbox.unreadThreads)
                .tag(FeedID.mailbox(accountKey: account.accountKey, mailboxID: mailbox.mailboxID))
                .listRowBackground(Color.clear)
                .dropTarget(
                    .mailbox(
                        accountKey: account.accountKey, mailboxID: mailbox.mailboxID,
                        role: mailbox.role, name: mailbox.name),
                    current: $dropTarget, accept: accept)
            }

            if hiddenMailboxCount(for: account) > 0 {
                Button {
                    withAnimation(standardAnimation) { showsHiddenLabels.toggle() }
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

    /// How one account's row is read out — the leaf alone in a flat account,
    /// and the leaf named before its ancestry where there is nesting. Never the
    /// drawn path: VoiceOver reads `Work / Q1` as "Work slash Q1".
    private func spokenName(
        of mailbox: MailboxSnapshot, in hierarchy: LabelHierarchy, nested: Bool
    ) -> String {
        nested ? hierarchy.spokenPath(for: mailbox) : mailbox.name
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
    ///
    /// - Parameters:
    ///   - role: The mailbox's role, or nil for a custom label.
    ///   - accent: The resolved theme's accent, which only Inbox uses. Passed
    ///     in rather than read here: this is a `static func` with no
    ///     environment of its own, and reaching for `Color.accentColor`
    ///     instead is exactly how a server-set accent stops at the sidebar —
    ///     the one row in it meant to carry the user's own colour.
    /// - Returns: The role's colour, or nil for a custom label, which takes a
    ///   hashed colour from its caller instead.
    static func tint(for role: MailboxRole?, accent: Color) -> Color? {
        switch role {
        case .none: nil
        case .inbox: accent
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

    private static func tint(for role: MailboxRole, accent: Color) -> Color {
        tint(for: Optional(role), accent: accent) ?? .secondary
    }

    // MARK: - Contents

    /// Only roles that actually exist somewhere. An account with no
    /// Archive binding — the default, since plMail creates it hidden —
    /// should not put an empty row in everyone's sidebar.
    private var unifiedRoles: [MailboxRole] {
        Self.unifiedRoles(in: sync.mailboxes)
    }

    /// The same list, for a caller that has no sidebar in front of it.
    ///
    /// Static so ⌘1…⌘9 in `MailView` numbers exactly the rows the sidebar
    /// draws. Computing the order twice is how ⌘3 ends up meaning Drafts on a
    /// keyboard and Sent on screen for an account whose Archive is hidden.
    static func unifiedRoles(in mailboxes: [MailboxSnapshot]) -> [MailboxRole] {
        let present = Set(mailboxes.compactMap(\.role))

        return [.inbox, .flagged, .snoozed, .drafts, .sent, .archive, .junk, .trash]
            .filter(present.contains)
    }

    /// Custom labels, collapsed across accounts by their user-scoped label
    /// id. That id is exactly why the server extension exists: matching on
    /// name instead would split "Work" in two the moment it was renamed in
    /// one account.
    ///
    /// Colour and path are taken from the first binding seen, which is safe for
    /// colour — it lives on the user-scoped label, not on the per-account
    /// binding, so every account agrees — and is the only available answer for
    /// the path, since nesting is expressed with per-account parent ids.
    private func labels(in hierarchy: LabelHierarchy) -> [LabelRow] {
        var byLabel: [LabelID: LabelRow] = [:]

        // A flat account pays nothing for paths: with no nesting anywhere,
        // every path equals its leaf and a second line under every row would
        // be noise that says nothing.
        let nested = hierarchy.hasNesting

        for mailbox in sync.mailboxes {
            guard mailbox.role == nil, let labelID = mailbox.labelID else { continue }

            byLabel[
                labelID,
                default: LabelRow(
                    labelID: labelID,
                    name: mailbox.name,
                    color: mailbox.color,
                    parentPath: nested ? hierarchy.parentPath(for: mailbox) : nil,
                    spokenPath: nested ? hierarchy.spokenPath(for: mailbox) : mailbox.name)
            ]
            .accountCount += 1
        }

        return byLabel.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Whether any custom label exists at all, for the row that offers to make
    /// the first one. Asked separately so the button does not have to build the
    /// whole collapsed list to look at its count.
    private var hasLabels: Bool {
        sync.mailboxes.contains { $0.role == nil && $0.labelID != nil }
    }

    private func unreadCount(for role: MailboxRole) -> Int {
        sync.mailboxes
            .filter { $0.role == role }
            .reduce(0) { $0 + $1.unreadThreads }
    }

    // MARK: - Drops

    /// A sidebar row a conversation can be dropped on.
    ///
    /// Carries everything the drop needs — the name for the undo bar, the role
    /// for the verb — because the row it came from is gone by the time the
    /// drop handler runs, and re-deriving it means searching `sync.mailboxes`
    /// for something that may have been deleted mid-drag.
    enum DropTarget: Hashable {
        /// A unified row: every account's mailbox with this role at once.
        case role(MailboxRole)
        /// A unified label, applied per account through its own binding — the
        /// whole reason the server exposes a user-scoped `labelId`.
        case unifiedLabel(labelID: LabelID, name: String)
        /// One account's mailbox, by id.
        case mailbox(accountKey: String, mailboxID: MailboxID, role: MailboxRole?, name: String)
    }

    /// Applies a drop, and reports whether it did anything.
    ///
    /// Deliberately narrow about which rows accept mail. Archive, Trash, Junk
    /// and labels are the four that correspond to a verb `MailActions` already
    /// has, is already undoable, and already reports failure through the same
    /// toast. Inbox, Sent and Drafts are reached by not-archiving, sending and
    /// writing; a drop that silently invented an "unarchive" would be a fifth
    /// code path with no undo behind it.
    private func accept(_ transfer: ThreadTransfer, on destination: DropTarget) -> Bool {
        guard let actions else { return false }

        let targets = transfer.targets(accounts: sync.accounts)

        guard targets.isEmpty == false else { return false }

        switch destination {
        case .role(let role), .mailbox(_, _, .some(let role), _):
            return move(targets, to: role, with: actions)

        case .unifiedLabel(let labelID, let name):
            Task { await actions.perform(.setLabel(true, labelID, name: name), on: targets) }
            return true

        case .mailbox(let accountKey, let mailboxID, .none, let name):
            // A custom label belongs to exactly one account, so only the
            // dragged conversations from that account can go on it. Dropping a
            // unified selection here applies the label to the part of it that
            // can take it rather than failing whole.
            let mine = targets.filter { $0.accountKey == accountKey }

            guard mine.isEmpty == false else { return false }

            Task {
                for target in mine {
                    await actions.setLabel(true, mailbox: mailboxID, named: name, target)
                }
            }

            return true
        }
    }

    /// The three role rows that are a move rather than a label.
    private func move(
        _ targets: [ActionTarget], to role: MailboxRole, with actions: MailActions
    ) -> Bool {
        switch role {
        case .archive:
            Task { await actions.perform(.archive, on: targets) }
        case .trash:
            Task { await actions.perform(.trash, on: targets) }
        case .junk:
            // No bulk verb for spam, so one call each — which also means one
            // undo each. Acceptable because dropping a multi-selection on Junk
            // is rare and the alternative is a bulk path that exists only here.
            Task {
                for target in targets {
                    await actions.setSpam(true, target)
                }
            }
        default:
            return false
        }

        return true
    }

    struct LabelRow: Identifiable {
        let labelID: LabelID
        let name: String
        /// The colour the user chose, carried from the binding so the row can
        /// draw it. Nil means *no colour chosen* and is the only case that may
        /// fall back to the hashed tint — a label deliberately coloured grey
        /// must not be repainted with something nobody picked.
        let color: LabelColor?
        /// The ancestors without the leaf, or nil for a top-level label and for
        /// an account with no nesting at all. Drawn as a caption because two
        /// labels named `Q1` under different parents are otherwise one row
        /// repeated twice.
        let parentPath: String?
        /// How the row is read out. Never the drawn path: VoiceOver says "Work
        /// slash Q1", which is unparseable by ear for a name that itself
        /// contains a slash.
        let spokenPath: String
        var accountCount = 0

        var id: LabelID { labelID }
    }
}

#endif
