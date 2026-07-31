#if os(iOS)

public import PLMailCore

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

    @Query private var entries: [StoredFeedEntry]
    @Query private var threads: [StoredThread]

    @State private var isLoadingMore = false

    public init(feed: FeedID, sync: MailSyncService) {
        self.feed = feed
        self.sync = sync

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
                ThreadRowView(thread: row.thread, accountLabel: accountLabel(for: row.entry))
                    .task { await loadMoreIfNeeded(at: row.entry) }
            }

            if degraded.isEmpty == false {
                degradedSection
            }
        }
        .listStyle(.plain)
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
        if case .failed(let message) = sync.status, entries.isEmpty == false {
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
