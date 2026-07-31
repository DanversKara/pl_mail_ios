import Network
import Observation
import PLMailCore
import SwiftData
import SwiftUI

/// Owns what outlives any one screen: the connection, the store, and the
/// decision about when the app is allowed to hold a live connection open.
@MainActor
@Observable
final class AppModel {
    private(set) var connection: ServerConnection?
    private(set) var hasLoaded = false

    let container = MailStack.makeContainer()

    /// Created once per connection rather than per view, so the live stream
    /// and the background refresh act on the same sync state the UI shows.
    private(set) var sync: MailSyncService?

    private let credentials = CredentialStore()
    private let monitor = NWPathMonitor()
    private var isMonitoring = false

    var store: SyncStore { SyncStore(modelContainer: container) }

    // MARK: - Connection

    func load() {
        guard hasLoaded == false else { return }

        // A malformed keychain entry means onboarding, not a crash: it is
        // replaceable, and the user can sign in again.
        connect(to: try? credentials.load())
        hasLoaded = true
    }

    func signedIn(_ connection: ServerConnection) {
        connect(to: connection)
    }

    func signOut() {
        try? credentials.delete()

        Task { [container] in
            // The cache belonged to that credential; leaving it would show the
            // previous account's mail behind the next sign-in screen.
            try? await SyncStore(modelContainer: container).deleteEverything()
        }

        Task { await sync?.endLiveUpdates() }
        connect(to: nil)
    }

    private func connect(to connection: ServerConnection?) {
        self.connection = connection

        guard let connection else {
            sync = nil
            outbox = nil
            return
        }

        let service = MailSyncService(connection: connection, store: store)
        service.onReauthenticationNeeded = { [weak self] in self?.signOut() }
        sync = service

        let sender = OutboxSender(
            outbox: Outbox(serverID: connection.host),
            client: service.jmapClient,
            store: store
        )
        outbox = sender

        // Anything queued from a previous run goes out as soon as there is a
        // client to send it with. Someone who wrote a message on a train and
        // then killed the app expects it gone by the time they look again.
        Task {
            await sender.refreshCount()
            sender.drain()
        }

        startMonitoringNetwork()
    }

    // MARK: - Lifecycle

    func scenePhaseChanged(to phase: ScenePhase) async {
        switch phase {
        case .active:
            // Coming back to the app is the most likely moment for the server
            // to have become reachable again.
            outbox?.drain()

            // Nothing is opened here: the live stream belongs to whichever
            // list is on screen, and opening it before one exists would hold a
            // server worker to show nothing.
            break

        case .inactive, .background:
            // Torn down immediately. The worker this holds is not the app's to
            // keep while it is not being looked at, and the server's pool is
            // small enough that one idle client is a real cost.
            await sync?.endLiveUpdates()
            BackgroundRefresh.schedule()

        @unknown default:
            await sync?.endLiveUpdates()
        }
    }

    /// Queued mail waiting to go out. Nil until there is a connection.
    private(set) var outbox: OutboxSender?

    func refreshInBackground() async {
        guard sync == nil else {
            await sync?.refreshInBackground()
            return
        }

        // Woken before any UI existed: rebuild just enough to do one pull.
        load()
        await sync?.refreshInBackground()
    }

    /// Reachability is the one signal worth reopening a tripped circuit for —
    /// time passing is not evidence that a NAS came back.
    private func startMonitoringNetwork() {
        guard isMonitoring == false else { return }

        isMonitoring = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }

            Task { @MainActor in
                await self?.sync?.networkPathChanged()
                // The network coming back is the other moment worth retrying:
                // the app may have been foregrounded for an hour on a train
                // with nothing to send to.
                self?.outbox?.drain()
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }
}
