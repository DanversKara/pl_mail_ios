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

    private let connection: ServerConnection
    private let onSignOut: () -> Void

    public init(
        connection: ServerConnection,
        store: SyncStore,
        onSignOut: @escaping () -> Void
    ) {
        self.connection = connection
        self.onSignOut = onSignOut
        _sync = State(wrappedValue: MailSyncService(connection: connection, store: store))
        _selectedFeed = State(wrappedValue: .unified(.inbox))
    }

    public var body: some View {
        NavigationSplitView {
            MailboxSidebarView(sync: sync, selection: $selectedFeed)
                .navigationTitle("plMail")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Server", systemImage: "gearshape") {
                            isShowingDiagnostics = true
                        }
                    }
                }
        } detail: {
            // No NavigationStack here. The split view already provides one
            // for the detail column, and nesting a second means the visible
            // bar belongs to the outer stack while the title is set on the
            // inner one — which shows up as a titleless list whenever the
            // detail is restored rather than pushed. The thread reader
            // pushes onto this column with `navigationDestination`.
            if let selectedFeed {
                ThreadListView(feed: selectedFeed, sync: sync)
            } else {
                ContentUnavailableView(
                    "Pick a mailbox", systemImage: "tray.2",
                    description: Text("Choose a list from the sidebar."))
            }
        }
        .task(id: selectedFeed) {
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
