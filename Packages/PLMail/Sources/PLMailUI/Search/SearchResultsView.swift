#if os(iOS)

public import PLMailCore

import SwiftUI

/// Search results.
///
/// The same merged feed as any other list — one query per account,
/// interleaved by date — so results page and survive a backgrounding
/// rather than being a special case that has to be rebuilt each time.
struct SearchResultsView: View {
    /// The settled query, which is what actually ran.
    let raw: String
    let sync: MailSyncService
    let actions: MailActions
    let outbox: OutboxSender
    @Binding var selection: ThreadRef?

    /// The field's live contents. The chips edit this rather than `raw`, so a
    /// chip tapped mid-keystroke narrows what is being typed instead of
    /// silently reverting to the last settled query.
    @Binding var queryText: String

    @State private var isSearching = false

    /// Read from the live text, so the tokens and the chips describe the same
    /// string the person is looking at. The results below are a debounce
    /// behind, which is the one place this view is deliberately not live.
    private var typed: ParsedSearchQuery { SearchQuery.parse(queryText) }
    private var parsed: ParsedSearchQuery { SearchQuery.parse(raw) }
    private var feed: FeedID { .search(raw) }

    var body: some View {
        Group {
            if parsed.isEmpty {
                ContentUnavailableView {
                    Label(.ui("Search your mail"), systemImage: "magnifyingglass")
                } description: {
                    Text(.ui(Self.help))
                }
            } else {
                ThreadListView(
                    feed: feed, sync: sync, actions: actions, outbox: outbox,
                    selection: $selection
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        // What can be added, then what was understood. The
                        // order matters: tapping a chip makes a token appear
                        // directly below it, which is the whole feedback loop.
                        SearchFilterChipsView(
                            query: typed, onChange: { queryText = $0 }, raw: queryText)

                        SearchTokensView(query: typed)
                    }
                    .background(.bar)
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
    /// web UI takes, and nobody discovers them by guessing — though by the time
    /// anyone reads this they have already been offered while typing.
    private static let help: String.LocalizationValue = """
        Use from:, to:, subject:, has:attachment, is:unread, is:starred, \
        in:inbox and before:/after: with a date. Anything else is searched \
        as text, and quoted words are searched as a phrase.
        """
}

#endif
