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
    @State private var actions: MailActions
    @State private var selectedFeed: FeedID?
    @State private var selectedThread: ThreadRef?
    /// Three columns by default on iPad. Left to the system on iPhone, where
    /// the split view is collapsed and this is ignored.
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var isShowingDiagnostics = false
    @State private var isSelectionActive = false
    @State private var composing: ComposeModel.Kind?
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
        sync: MailSyncService,
        store: SyncStore,
        onSignOut: @escaping () -> Void
    ) {
        self.connection = connection
        self.store = store
        self.onSignOut = onSignOut
        // Scoped to the server, so signing into another one cannot serve the
        // previous server's attachments out of a shared directory.
        blobs = BlobCache(serverID: connection.host)
        // Owned by the app rather than this view: the live stream and the
        // background refresh have to act on the same sync state the UI shows.
        _sync = State(wrappedValue: sync)
        _actions = State(
            wrappedValue: MailActions(client: sync.jmapClient, store: store))
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
                sync: sync,
                blobs: blobs,
                actions: actions,
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

    /// Which account a new message is sent from.
    ///
    /// The account whose mailbox is on screen when there is one, so composing
    /// from a specific inbox sends from that address rather than whichever
    /// account happens to sort first.
    private var composeAccount: AccountSnapshot? {
        if case .mailbox(let accountKey, _) = selectedFeed {
            return sync.accounts.first { $0.accountKey == accountKey }
        }

        return sync.accounts.first
    }

    /// The compose button, where every mail app has put it for a decade.
    private var composeButton: some View {
        Button {
            composing = .new
        } label: {
            Label("New message", systemImage: "square.and.pencil")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 56, height: 56)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
                .shadow(radius: 6, y: 3)
        }
        .padding(.trailing, 20)
        // Sits close to the bottom, where a thumb is, and steps up out of
        // the way only while the undo bar is actually showing rather than
        // reserving that space permanently for a toast that is usually
        // absent.
        .padding(.bottom, isUndoBarShowing ? 84 : 20)
        .animation(.snappy(duration: 0.2), value: isUndoBarShowing)
        .accessibilityLabel("New message")
        // Gmail's "c", and ⌘N for anyone who expects the Mac convention.
        // Both reach the same button, so neither is a second code path.
        .keyboardShortcut("c", modifiers: [])
    }

    private var isUndoBarShowing: Bool {
        actions.pending != nil || actions.failure != nil
    }

    private var isSearching: Bool {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty == false
    }

    /// The sidebar, or the results that replaced it on a narrow screen.
    ///
    /// Compact: the sidebar *is* the screen, so results have to appear where
    /// the field is — putting them one column over would mean typing here and
    /// navigating there.
    @ViewBuilder
    private var sidebarContent: some View {
        if isSearching, sizeClass == .compact {
            SearchResultsView(
                raw: settledSearch, sync: sync, actions: actions,
                selection: $selectedThread)
        } else {
            MailboxSidebarView(sync: sync, selection: $selectedFeed)
        }
    }

    /// The middle column: results while searching, otherwise the mailbox.
    @ViewBuilder
    private var listContent: some View {
        if isSearching, sizeClass != .compact {
            SearchResultsView(
                raw: settledSearch, sync: sync, actions: actions,
                selection: $selectedThread)
        } else if let selectedFeed {
            // `.inline`, not large: a large title silently fails to render
            // when this column is restored rather than pushed, which is
            // exactly the cold-launch path, and an untitled list reads as a
            // bug.
            ThreadListView(
                feed: selectedFeed, sync: sync, actions: actions,
                selection: $selectedThread, isSelectionActive: $isSelectionActive
            )
        } else {
            ContentUnavailableView(
                "Pick a mailbox", systemImage: "tray.2",
                description: Text("Choose a list from the sidebar."))
        }
    }

    public var body: some View {
        // Three columns — mailboxes, conversations, message — which is the
        // web UI's three regions and what an iPad has room for. On iPhone the
        // split view collapses the same three into one stack, so `Back`
        // genuinely means back and no second layout has to be maintained.
        NavigationSplitView(columnVisibility: $columns) {
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
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            listContent
                // Wider than the system default, which is sized for a list of
                // short titles. A conversation row carries an avatar, a
                // subject and a snippet, and at the default width the subject
                // truncates on almost every message. The minimum matters more
                // than the ideal: when the detail column is hungry the split
                // view hands this one its minimum, so a generous ideal alone
                // changes nothing.
                .navigationSplitViewColumnWidth(min: 380, ideal: 420, max: 520)
        } detail: {
            // Its own stack so the reader can push further — an attachment
            // preview, a sender's other mail — without disturbing the columns
            // to its left.
            NavigationStack {
                if let selectedThread {
                    reader(for: selectedThread)
                } else {
                    ContentUnavailableView(
                        "No conversation selected", systemImage: "envelope",
                        description: Text("Pick a message to read it here."))
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Over the whole split view rather than over the list column, so on a
        // tablet it sits at the window's right edge instead of floating in the
        // middle against a column divider. Collapsed on iPhone the two are the
        // same place.
        .overlay(alignment: .bottomTrailing) {
            // The bulk action bar occupies this corner while a selection is
            // up, and composing is not something anyone reaches for
            // mid-selection anyway.
            if isSelectionActive == false { composeButton }
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
        // Switching mailbox leaves the reader showing a thread that is no
        // longer in the list beside it — on a wide layout the two columns
        // would visibly disagree.
        .onChange(of: selectedFeed) { _, _ in selectedThread = nil }
        .task(id: selectedFeed) {
            guard let selectedFeed else { return }

            await sync.start(feed: selectedFeed)

            // Only once a list is actually on screen, and torn down as soon as
            // it is not — each stream holds a server worker for its life.
            await sync.beginLiveUpdates(feed: selectedFeed)
        }
        .sheet(item: $composing) { kind in
            if let account = composeAccount {
                ComposeView(
                    kind: kind,
                    accountKey: account.accountKey,
                    accountID: account.accountID,
                    client: sync.jmapClient,
                    store: store
                )
            }
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
