#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftData
import SwiftUI

/// The conversation list.
///
/// Driven entirely by `@Query` over the feed table, never by the network.
/// That is what makes a cold launch show mail immediately and what keeps
/// the list intact when the server is unreachable — which for a NAS is a
/// normal Tuesday, not an error state.
public struct ThreadListView: View {
    private let feed: FeedID
    private let sync: MailSyncService
    private let actions: MailActions

    /// Owned by the split view, not by this list.
    ///
    /// Selection *is* the navigation on a wide layout — it fills the third
    /// column — and on a narrow one the collapsed split view turns the same
    /// binding into a push. One piece of state drives both, which is what
    /// keeps the open thread open across a rotation or a Stage Manager
    /// resize instead of dumping the reader.
    @Binding private var selection: ThreadRef?
    /// Raised while a bulk selection is up, so the compose button can get out
    /// of the way — it occupies the same corner as the action bar's last
    /// button and would sit on top of Trash.
    @Binding private var isSelectionActive: Bool

    @Query private var entries: [StoredFeedEntry]
    @Query private var threads: [StoredThread]

    @State private var isLoadingMore = false
    /// Conversations picked out for a bulk action. Non-empty *is* selection
    /// mode: there is no separate toggle to get out of sync with it.
    @State private var checked: Set<ThreadRef> = []
    @State private var isPickingBulkLabel = false
    /// The conversation whose exact snooze time is being picked.
    @State private var snoozing: ActionTarget?
    /// The conversation whose labels are being edited. A target rather than a
    /// Bool, so the sheet cannot outlive the row that opened it.
    @State private var labelling: ActionTarget?

    public init(
        feed: FeedID,
        sync: MailSyncService,
        actions: MailActions,
        selection: Binding<ThreadRef?>,
        isSelectionActive: Binding<Bool> = .constant(false)
    ) {
        self.feed = feed
        self.sync = sync
        self.actions = actions
        _selection = selection
        _isSelectionActive = isSelectionActive

        let feedID = feed.rawValue

        _entries = Query(
            filter: #Predicate<StoredFeedEntry> { $0.feedID == feedID },
            sort: \.sortDate,
            order: .reverse
        )
        _threads = Query()
    }

    public var body: some View {
        List {
            ForEach(rows, id: \.entry.uid) { row in
                // A Button rather than List's own selection binding. The
                // system's selected appearance is a hard blue fill that also
                // recolours the row's text, and none of it is restylable — on
                // a mail list, where the row's own colours carry unread and
                // starred, that erases the state it is sitting on top of.
                // Owning the tap means owning the highlight.
                Button {
                    let ref = ThreadRef(thread: row.thread)

                    if isSelecting {
                        toggle(ref)
                    } else {
                        selection = ref
                    }
                } label: {
                    ThreadRowView(
                        thread: row.thread,
                        accountLabel: accountLabel(for: row.entry),
                        isSelected: checked.contains(ThreadRef(thread: row.thread)),
                        isOpen: selection == ThreadRef(thread: row.thread),
                        snippet: sync.snippets["\(row.entry.accountKey)#\(row.entry.emailID)"],
                        onToggleStar: {
                            act {
                                await actions.setFlagged(
                                    row.thread.isFlagged == false, target(for: row.thread))
                            }
                        },
                        onToggleSelection: { toggle(ThreadRef(thread: row.thread)) }
                    )
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(.init(top: 1, leading: 6, bottom: 1, trailing: 6))
                // Hiding the *scroll* background is not enough: rows paint
                // their own on top of it, which on a separated pane shows as
                // an opaque band sitting over the card.
                .listRowBackground(Color.clear)
                .task { await loadMoreIfNeeded(at: row.entry) }
                // Both directions, both undoable, and everything a swipe does
                // is also reachable from the row's context menu — a gesture
                // must never be the only way to reach an action.
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        act { await actions.archive(target(for: row.thread)) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(.green)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        act { await actions.trash(target(for: row.thread)) }
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }

                    Button {
                        act {
                            await actions.setSeen(
                                row.thread.isUnread, target(for: row.thread))
                        }
                    } label: {
                        Label(
                            row.thread.isUnread ? "Read" : "Unread",
                            systemImage: row.thread.isUnread ? "envelope.open" : "envelope.badge")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    Button {
                        act {
                            await actions.setFlagged(
                                row.thread.isFlagged == false, target(for: row.thread))
                        }
                    } label: {
                        Label(
                            row.thread.isFlagged ? "Remove star" : "Star",
                            systemImage: row.thread.isFlagged ? "star.slash" : "star")
                    }

                    Button {
                        act { await actions.setSeen(row.thread.isUnread, target(for: row.thread)) }
                    } label: {
                        Label(
                            row.thread.isUnread ? "Mark as read" : "Mark as unread",
                            systemImage: row.thread.isUnread ? "envelope.open" : "envelope.badge")
                    }

                    Button {
                        labelling = target(for: row.thread)
                    } label: {
                        Label("Labels", systemImage: "tag")
                    }

                    Menu {
                        SnoozeMenu(
                            isSnoozed: row.thread.snoozedUntil != nil,
                            onPick: { until in
                                act { await actions.snooze(target(for: row.thread), until: until) }
                            },
                            onPickExact: { snoozing = target(for: row.thread) }
                        )
                    } label: {
                        Label("Snooze", systemImage: "clock")
                    }

                    Button {
                        act { await actions.archive(target(for: row.thread)) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }

                    Button(role: .destructive) {
                        act { await actions.trash(target(for: row.thread)) }
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
            }

            if degraded.isEmpty == false {
                degradedSection
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        // The pane behind supplies the surface; a List painting its own would
        // square off the pane's rounded corners.
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { bulkBar }
        .onChange(of: isSelecting) { _, active in isSelectionActive = active }
        .sheet(isPresented: $isPickingBulkLabel) {
            BulkLabelPickerView(targets: checkedTargets, sync: sync, actions: actions) {
                checked = []
            }
        }
        .sheet(item: $snoozing) { target in
            SnoozeDatePicker { until in
                act { await actions.snooze(target, until: until) }
            }
        }
        .sheet(item: $labelling) { target in
            LabelPickerView(target: target, sync: sync, actions: actions, store: sync.store)
        }
        .undoOverlay(actions)
        .safeAreaInset(edge: .top, spacing: 0) { offlineBanner }
        .refreshable { await sync.refresh(feed: feed) }
        .overlay { emptyState }
        // The title carries the count while selecting, so the number is where
        // the eye already is rather than in a second bar.
        .navigationTitle(
            isSelecting
                ? "\(checked.count) selected" : feed.title(mailboxes: sync.mailboxes)
        )
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { checked = [] }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(allChecked ? "Deselect all" : "Select all") {
                        checked = allChecked ? [] : Set(rows.map { ThreadRef(thread: $0.thread) })
                    }
                }
            }
        }
        // Inline, not large. A large title silently fails to render when
        // the split view restores its detail column rather than pushing
        // it, which is exactly the cold-launch path — and an untitled list
        // reads as a bug. Inline also matches the list-then-reader flow.
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Selection

    private var isSelecting: Bool { checked.isEmpty == false }

    private func toggle(_ ref: ThreadRef) {
        if checked.contains(ref) {
            checked.remove(ref)
        } else {
            checked.insert(ref)
        }
    }

    /// The selected conversations, as things an action can be applied to.
    ///
    /// Resolved from the rows on screen rather than stored alongside the
    /// selection: a thread that gained a reply since it was ticked should be
    /// acted on whole, and a thread that vanished should drop out silently
    /// rather than sending ids the server no longer has.
    private var checkedTargets: [ActionTarget] {
        rows
            .filter { checked.contains(ThreadRef(thread: $0.thread)) }
            .map { target(for: $0.thread) }
    }

    /// The bulk action bar.
    ///
    /// Only the four actions that make sense on a heap of conversations, plus
    /// labels. Reply is deliberately absent — replying to forty threads at once
    /// is not an operation.
    @ViewBuilder
    private var bulkBar: some View {
        if isSelecting {
            VStack(spacing: 0) {
                Divider()

                HStack(spacing: 0) {
                    bulkButton("Archive", "archivebox") { .archive }
                    bulkButton("Labels", "tag", action: nil) { isPickingBulkLabel = true }
                    bulkButton(
                        anyUnread ? "Read" : "Unread",
                        anyUnread ? "envelope.open" : "envelope.badge"
                    ) {
                        .setSeen(anyUnread)
                    }
                    bulkButton(
                        anyUnstarred ? "Star" : "Unstar", anyUnstarred ? "star" : "star.slash"
                    ) {
                        .setFlagged(anyUnstarred)
                    }
                    bulkButton("Trash", "trash", role: .destructive) { .trash }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(.bar)
            .transition(.move(edge: .bottom))
        }
    }

    private func bulkButton(
        _ title: String,
        _ symbol: String,
        role: ButtonRole? = nil,
        action: (() -> MailActions.BulkAction)? = nil,
        perform: (() -> Void)? = nil
    ) -> some View {
        Button(role: role) {
            if let action {
                // Both resolved *before* the selection is cleared. The action
                // is a closure over `checked` — `anyUnstarred` and friends read
                // it — so evaluating it afterwards computes the verb against an
                // empty set and sends the opposite of what the button said.
                let targets = checkedTargets
                let resolved = action()

                // Cleared before the request, not after: leaving rows ticked
                // while an archive is in flight invites a second tap on a
                // selection that is already on its way out.
                checked = []
                Task { await actions.perform(resolved, on: targets) }
            } else {
                perform?()
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.body)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
    }

    /// Mixed selections get the action that changes the most rows: ticking a
    /// read and an unread message and pressing Read should leave both read,
    /// not flip each one.
    private var anyUnread: Bool {
        rows.contains { checked.contains(ThreadRef(thread: $0.thread)) && $0.thread.isUnread }
    }

    /// Only the rows actually loaded. "Select all" cannot mean the whole
    /// mailbox: the list is paged, and acting on messages nobody has seen is
    /// not something a button should quietly offer.
    private var allChecked: Bool {
        rows.isEmpty == false && checked.count >= rows.count
    }

    private var anyUnstarred: Bool {
        rows.contains {
            checked.contains(ThreadRef(thread: $0.thread)) && $0.thread.isFlagged == false
        }
    }

    // MARK: - Rows

    /// The feed table gives the order; the thread table gives the content.
    /// Joined here rather than denormalised into the feed row so that a
    /// thread changing — read, starred, a new reply — updates every list it
    /// appears in without touching the ordering.
    private var rows: [(entry: StoredFeedEntry, thread: StoredThread)] {
        let byKey = Dictionary(
            threads.map { ("\($0.accountKey)#\($0.threadID)", $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return entries.compactMap { entry in
            guard let thread = byKey["\(entry.accountKey)#\(entry.threadID)"] else {
                return nil
            }

            return (entry, thread)
        }
    }

    /// What an action applies to.
    ///
    /// The whole thread: archiving one reply and leaving the rest is not
    /// something anyone means, and this is a list of conversations.
    private func target(for thread: StoredThread) -> ActionTarget {
        ActionTarget(
            threadID: thread.threadID,
            accountKey: thread.accountKey,
            accountID: sync.accounts.first { $0.accountKey == thread.accountKey }?.accountID
                ?? AccountID(""),
            emailIDs: thread.emailIDs.map { EmailID(rawValue: $0) }
        )
    }

    private func act(_ work: @escaping @MainActor () async -> Void) {
        Task { await work() }
    }

    private func accountLabel(for entry: StoredFeedEntry) -> String? {
        guard sync.accounts.count > 1 else { return nil }

        return sync.accounts.first { $0.accountKey == entry.accountKey }?.name
    }

    // MARK: - Paging

    private func loadMoreIfNeeded(at entry: StoredFeedEntry) async {
        guard entry.uid == entries.last?.uid, isLoadingMore == false else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        await sync.loadMore(of: feed)
    }

    // MARK: - States

    /// Offline is a state, not an error.
    ///
    /// A home server is unreachable far more often than a cloud one — it
    /// reboots, the VPN drops, someone is upstairs. Showing cached mail
    /// with a quiet line saying so is honest; showing it silently would
    /// let someone believe they had seen everything.
    @ViewBuilder
    private var offlineBanner: some View {
        if let message = sync.bannerMessage, entries.isEmpty == false {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                Text(message)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if entries.isEmpty {
            switch sync.status {
            case .syncing:
                ProgressView()

            // A rejected credential is not a network problem, and offering
            // "try again" for it would send someone to check their wifi.
            case .unauthenticated:
                ContentUnavailableView {
                    Label("Sign in again", systemImage: "key.slash")
                } description: {
                    Text(
                        """
                        \(sync.serverID) rejected this app password. It may have been revoked in \
                        Settings → App passwords, or the account may have been removed.
                        """
                    )
                } actions: {
                    Button("Sign out", role: .destructive) { sync.requestReauthentication() }
                }

            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't reach your server", systemImage: "wifi.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await sync.refresh(feed: feed) } }
                }
            case .idle:
                ContentUnavailableView(
                    "No mail here",
                    systemImage: "tray",
                    description: Text(
                        "This list covers mail plMail has synced. Older mail arrives as the sync window widens."
                    )
                )
            }
        }
    }

    /// One failing account is named without emptying the list, because
    /// multi-account is the normal case: the other mailboxes are still
    /// perfectly usable.
    private var degradedSection: some View {
        Section {
            ForEach(degraded, id: \.key) { entry in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountName(entry.key)).font(.footnote)
                        Text(entry.value).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Some accounts didn't sync")
        }
    }

    private var degraded: [(key: String, value: String)] {
        sync.degradedAccounts.sorted { $0.key < $1.key }
    }

    private func accountName(_ accountKey: String) -> String {
        sync.accounts.first { $0.accountKey == accountKey }?.name ?? accountKey
    }
}

#endif
