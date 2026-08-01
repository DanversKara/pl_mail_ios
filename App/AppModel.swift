import Network
import Observation
import PLMailCore
import SwiftData
import SwiftUI
import UIKit

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

        #if DEBUG
        // A UI test that only passes on the second run — because the
        // first one left an account signed in — is worse than no test.
        // Debug-only and launch-argument-only: there is no way to reach
        // this from a shipped build, which matters because what it does
        // is delete someone's mailbox.
        if UserDefaults.standard.bool(forKey: "plmail.resetForUITests") {
            try? credentials.delete()

            let container = container
            let semaphore = DispatchSemaphore(value: 0)

            // Synchronously, unlike `signOut`: onboarding is about to be
            // built, and a store deleted underneath it a moment later
            // would race with the first sync.
            Task.detached {
                try? await SyncStore(modelContainer: container).deleteEverything()
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 5)
        }
        #endif

        // A malformed keychain entry means onboarding, not a crash: it is
        // replaceable, and the user can sign in again.
        connect(to: try? credentials.load())
        hasLoaded = true
    }

    func signedIn(_ connection: ServerConnection) {
        connect(to: connection)

        Task { await requestPushIfUseful() }
    }

    func signOut() {
        // Before the credential goes: a device that keeps its registration
        // would go on being woken for a mailbox it can no longer read.
        if let push {
            Task { await push.unregister() }
        }

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
            push = nil
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
        push = PushRegistrar(client: service.jmapClient)

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

            // Mail held for a time is the one thing that makes an earlier
            // wake-up worth asking for. The system decides whether to grant
            // it, which is why the interface promises "at the first check
            // after" rather than the time itself.
            BackgroundRefresh.schedule(noLaterThan: outbox?.nextDueAt)

        @unknown default:
            await sync?.endLiveUpdates()
        }
    }

    /// Queued mail waiting to go out. Nil until there is a connection.
    private(set) var outbox: OutboxSender?

    /// Push registration. Nil until there is a server to register with.
    private var push: PushRegistrar?
    private var pushDelegate: PushDelegate?

    /// Wires the delegate's callbacks up.
    ///
    /// Registration is asked for here rather than at first launch: a
    /// notification prompt before someone has seen a single message is the
    /// prompt everyone denies, and a denial is effectively permanent.
    func adopt(_ delegate: PushDelegate) {
        guard pushDelegate == nil else { return }

        pushDelegate = delegate

        delegate.onToken = { [weak self] token in
            await self?.push?.register(token: token, deviceName: UIDevice.current.name)
        }

        delegate.onSilentPush = { [weak self] in
            // Exactly what a foreground refresh does. A push is a hint that
            // it is worth pulling now, not a delivery mechanism.
            await self?.sync?.refreshInBackground()
        }

        Task { await requestPushIfUseful() }
    }

    func refreshInBackground() async {
        // Woken before any UI existed: rebuild just enough to do one pull.
        if sync == nil { load() }

        await sync?.refreshInBackground()

        // The other half of a background wake, and the only thing that gets a
        // scheduled message out while nobody is looking at the app. Awaited
        // rather than fired off: the task reports itself complete when this
        // returns, and the system may suspend us on the next line.
        outbox?.drain()
        await outbox?.settle()

        // Resubmitted now that the queue is known: the run was rescheduled
        // before it started, when nothing here had been read yet, and a
        // request with the same identifier replaces that one.
        BackgroundRefresh.schedule(noLaterThan: outbox?.nextDueAt)
    }

    /// Registering and prompting are two different decisions.
    ///
    /// **Registering** for remote notifications needs no permission, shows
    /// nothing, and is what lets a silent push wake the app to sync. It costs
    /// a token. Do it whenever there is a server.
    ///
    /// **Prompting** for alerts spends a one-shot: refuse it and it never
    /// appears again without a trip to Settings. That is spent only on a
    /// server that advertises an APNs sender — against one without, granting
    /// it would deliver precisely nothing.
    ///
    /// Conflating the two is what made the first version of this untestable:
    /// gating registration behind the prompt meant an unsupported server
    /// never registered, so nothing could be delivered even by hand.
    private func requestPushIfUseful() async {
        PushDelegate.registerForSilentPushes()

        guard let push, await push.isSupported() else { return }

        await PushDelegate.requestAuthorization()
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
