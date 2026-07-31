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

    @Query private var entries: [StoredFeedEntry]
    @Query private var threads: [StoredThread]

    @State private var isLoadingMore = false

    public init(
        feed: FeedID,
        sync: MailSyncService,
        actions: MailActions,
        selection: Binding<ThreadRef?>
    ) {
        self.feed = feed
        self.sync = sync
        self.actions = actions
        _selection = selection

        let feedID = feed.rawValue

        _entries = Query(
            filter: #Predicate<StoredFeedEntry> { $0.feedID == feedID },
            sort: \.sortDate,
            order: .reverse
        )
        _threads = Query()
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(rows, id: \.entry.uid) { row in
                ThreadRowView(
                    thread: row.thread,
                    accountLabel: accountLabel(for: row.entry)
                ) {
                    act {
                        await actions.setFlagged(
                            row.thread.isFlagged == false, target(for: row.thread))
                    }
                }
                .tag(ThreadRef(thread: row.thread))
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
            }
        }
        .listStyle(.plain)
        .undoOverlay(actions)
        .safeAreaInset(edge: .top, spacing: 0) { offlineBanner }
        .refreshable { await sync.refresh(feed: feed) }
        .overlay { emptyState }
        .navigationTitle(feed.title(mailboxes: sync.mailboxes))
        // Inline, not large. A large title silently fails to render when
        // the split view restores its detail column rather than pushing
        // it, which is exactly the cold-launch path — and an untitled list
        // reads as a bug. Inline also matches the list-then-reader flow.
        .navigationBarTitleDisplayMode(.inline)
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
