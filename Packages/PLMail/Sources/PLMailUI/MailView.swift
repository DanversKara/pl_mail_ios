#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// The mail app.
///
/// A `NavigationSplitView` on both idioms: it collapses to a stack on
/// iPhone by itself, and expands to the sidebar-plus-list layout the web UI
/// uses on iPad — with one piece of state driving both, so a rotation or a
/// Stage Manager resize keeps the selection rather than resetting it.
public struct MailView: View {
    @State private var sync: MailSyncService
    @State private var selectedFeed: FeedID?
    @State private var isShowingDiagnostics = false
    @State private var searchText = ""
    /// Debounced separately from `searchText`, so a keystroke does not start a
    /// query against someone's home server.
    @State private var settledSearch = ""

    /// Where results belong depends on the layout, and the search field can
    /// only live in the sidebar — the detail column's navigation bar is not
    /// owned by its own stack when the split view collapses, so a field
    /// attached there simply never renders.
    ///
    /// Compact: the sidebar *is* the screen, so results replace it in place.
    /// Regular: the sidebar stays as navigation and results fill the detail,
    /// which is where a wide layout expects a list.
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let connection: ServerConnection
    private let store: SyncStore
    private let blobs: BlobCache
    private let onSignOut: () -> Void

    public init(
        connection: ServerConnection,
        store: SyncStore,
        onSignOut: @escaping () -> Void
    ) {
        self.connection = connection
        self.store = store
        self.onSignOut = onSignOut
        // Scoped to the server, so signing into another one cannot serve the
        // previous server's attachments out of a shared directory.
        blobs = BlobCache(serverID: connection.host)
        _sync = State(wrappedValue: MailSyncService(connection: connection, store: store))
        _selectedFeed = State(wrappedValue: .unified(.inbox))
    }

    /// The reader for one thread.
    ///
    /// Built here rather than in the row so it gets the sync service's own
    /// client: one cached session, one concurrency gate.
    @ViewBuilder
    private func reader(for ref: ThreadRef) -> some View {
        if let account = sync.accounts.first(where: { $0.accountKey == ref.accountKey }) {
            ThreadReaderView(
                threadID: ref.threadID,
                accountKey: ref.accountKey,
                accountID: account.accountID,
                subject: ref.subject,
                client: sync.jmapClient,
                store: store,
                blobs: blobs,
                credential: connection.credential
            )
        } else {
            // The account went away between the row rendering and the push —
            // a disconnected mailbox, or a sign-out mid-navigation.
            ContentUnavailableView(
                "This mailbox is no longer connected",
                systemImage: "tray.slash"
            )
        }
    }

    private var isSearching: Bool {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty == false
    }

    /// The sidebar, or the results that replaced it on a narrow screen.
    @ViewBuilder
    private var sidebarContent: some View {
        if isSearching, sizeClass == .compact {
            SearchResultsView(raw: settledSearch, sync: sync)
                .navigationDestination(for: ThreadRef.self, destination: reader(for:))
        } else {
            MailboxSidebarView(sync: sync, selection: $selectedFeed)
        }
    }

    public var body: some View {
        NavigationSplitView {
            sidebarContent
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search mail"
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .navigationTitle("plMail")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Server", systemImage: "gearshape") {
                            isShowingDiagnostics = true
                        }
                    }
                }
        } detail: {
            // The detail column needs its own stack for the list-to-reader
            // push. Note the list titles itself `.inline`: a *large* title
            // silently fails to render when this column is restored rather
            // than pushed, which is exactly the cold-launch path.
            NavigationStack {
                if let selectedFeed {
                    ThreadListView(feed: selectedFeed, sync: sync)
                        .navigationDestination(for: ThreadRef.self, destination: reader(for:))
                } else {
                    ContentUnavailableView(
                        "Pick a mailbox", systemImage: "tray.2",
                        description: Text("Choose a list from the sidebar."))
                }
            }
        }
        .task(id: searchText) {
            // 350ms: long enough that typing a word is one query rather than
            // five, short enough not to feel laggy.
            try? await Task.sleep(for: .milliseconds(350))

            guard Task.isCancelled == false else { return }

            let abandoned = settledSearch
            settledSearch = searchText

            if searchText.isEmpty, abandoned.isEmpty == false {
                await sync.discardSearch(feed: .search(abandoned))
            }
        }
        .task(id: selectedFeed) {
            // A rejected credential means onboarding, not a retry loop.
            sync.onReauthenticationNeeded = onSignOut

            guard let selectedFeed else { return }
            await sync.start(feed: selectedFeed)
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            ServerDiagnosticsView(
                connection: connection,
                sync: sync,
                onSignOut: onSignOut
            )
        }
    }
}

#endif
