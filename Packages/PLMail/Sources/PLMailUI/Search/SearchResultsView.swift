#if os(iOS)

public import PLMailCore

import SwiftUI

/// Search results.
///
/// The same merged feed as any other list — one query per account,
/// interleaved by date — so results page and survive a backgrounding
/// rather than being a special case that has to be rebuilt each time.
struct SearchResultsView: View {
    let raw: String
    let sync: MailSyncService
    let actions: MailActions
    let outbox: OutboxSender
    @Binding var selection: ThreadRef?

    @State private var isSearching = false

    private var parsed: ParsedSearchQuery { SearchQuery.parse(raw) }
    private var feed: FeedID { .search(raw) }

    var body: some View {
        Group {
            if parsed.isEmpty {
                ContentUnavailableView {
                    Label(.ui("Search your mail"), systemImage: "magnifyingglass")
                } description: {
                    Text(Self.help)
                }
            } else {
                ThreadListView(
                    feed: feed, sync: sync, actions: actions, outbox: outbox,
                    selection: $selection
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    SearchTokensView(query: parsed)
                }
            }
        }
        // Re-runs whenever the typed string settles on something new; the
        // debounce lives in the caller so a keystroke does not start a
        // query against someone's NAS.
        .task(id: raw) {
            guard parsed.isEmpty == false else { return }

            isSearching = true
            defer { isSearching = false }

            await sync.search(feed: feed)
        }
    }

    /// The operators, stated rather than hidden. They are the same ones the
    /// web UI takes, and nobody discovers them by guessing.
    private static let help = """
        Use from:, to:, subject:, has:attachment, is:unread, is:starred, \
        in:inbox and before:/after: with a date. Anything else is searched \
        as text, and quoted words are searched as a phrase.
        """
}

#endif
