import Foundation
import JMAPKit
import OSLog
import Observation

/// Drives syncing for the connected server.
///
/// Owns the account and mailbox structure, and one ``UnifiedFeed`` per list.
/// The merge is what makes several accounts read as one inbox; this type is
/// what decides which accounts and which mailboxes go into it.
///
/// Delta sync through `Email/changes` slots in alongside: it updates objects,
/// where the merge owns ordering.
@MainActor
@Observable
public final class MailSyncService {
    public enum Status: Equatable, Sendable {
        case idle
        case syncing
        /// The server answered, and said no. Distinct from `failed` because
        /// the remedy is different: a revoked app password is not something
        /// retrying fixes, and presenting it as a network problem sends the
        /// user to check their wifi instead of their credential.
        case unauthenticated
        case failed(message: String)
    }

    public private(set) var status: Status = .idle
    public private(set) var accounts: [AccountSnapshot] = []
    public private(set) var mailboxes: [MailboxSnapshot] = []

    /// Accounts that failed while others succeeded.
    ///
    /// One unreachable account must not blank the whole list — with several
    /// mailboxes connected, that is the difference between "my work mail is
    /// down" and "the app is broken".
    public private(set) var degradedAccounts: [String: String] = [:]

    /// Highlighted match text, keyed by `accountKey#emailId`.
    ///
    /// In memory rather than in the store: it belongs to one query rather than
    /// to the message, it is meaningless the moment the search text changes,
    /// and the store's rule is that everything in it is reconstructible cache
    /// — this is reconstructible, but only alongside a query nobody kept.
    public private(set) var snippets: [String: String] = [:]

    /// One merge per feed, so each keeps its own buffers and cursors.
    private var merges: [FeedID: UnifiedFeed] = [:]
    /// Which accounts each merge was built for. A change means it has to be
    /// rebuilt — an account added or removed changes what is being merged.
    private var mergedAccounts: [FeedID: Set<String>] = [:]

    /// When the server was last successfully reached.
    ///
    /// Shown as "last checked" rather than implying live delivery. Without
    /// APNs there is no true background push, and a client that suggests
    /// otherwise is lying about mail the user has not been told about.
    public private(set) var lastCheckedAt: Date?

    private let connection: ServerConnection
    private let client: JMAPClient
    /// Exposed because views that mutate — the label picker — need to read
    /// back what the store actually holds after an action, rather than
    /// assuming their optimistic change stuck.
    public let store: SyncStore
    private let delta: DeltaSync
    private let breaker: CircuitBreaker
    private let events: EventSourceClient
    private let logger = Logger(subsystem: "de.plmail", category: "sync")

    /// Which feed is on screen, so a push refreshes that list and not every
    /// list the app has ever built.
    private var visibleFeed: FeedID?

    public init(connection: ServerConnection, store: SyncStore) {
        self.connection = connection
        let client = connection.makeClient()
        self.client = client
        self.store = store
        delta = DeltaSync(client: client, store: store)
        breaker = CircuitBreaker()
        events = EventSourceClient(client: client, credential: connection.credential)
    }

    public var serverID: String { connection.host }

    /// Shared with the reader so both go through one cached session and one
    /// concurrency gate. A second client would mean a second session fetch and
    /// a gate that does not know about the other's in-flight requests.
    public var jmapClient: JMAPClient { client }
    public var serverConnection: ServerConnection { connection }

    /// Called when the stored credential is no longer accepted, so the app can
    /// return to onboarding. Set by whoever owns the sign-out path.
    public var onReauthenticationNeeded: (() -> Void)?

    public func requestReauthentication() {
        onReauthenticationNeeded?()
    }

    /// What to say over a list that still has cached mail in it.
    ///
    /// Nil when there is nothing worth interrupting for — a successful sync,
    /// or one still in flight.
    public var bannerMessage: String? {
        switch status {
        case .idle, .syncing: nil
        case .unauthenticated: "\(serverID) rejected this app password."
        case .failed(let message): message
        }
    }

    // MARK: - Liveness

    /// Starts listening for changes.
    ///
    /// Foreground only, and only while a list is actually on screen. Each
    /// connection holds a PHP worker for its life, and on a home NAS the pool
    /// is small enough that an idle app keeping one open is a real cost to
    /// everyone else using the server.
    public func beginLiveUpdates(feed: FeedID) async {
        visibleFeed = feed

        await events.start { [weak self] change in
            await self?.handle(change)
        }
    }

    /// Stops listening. Called the moment the app stops being frontmost.
    public func endLiveUpdates() async {
        await events.stop()
    }

    /// A push says only that a state token moved; this finds out what.
    private func handle(_ change: StateChange) async {
        let outcome = await delta.pull(accounts: accounts)

        lastCheckedAt = .now

        guard outcome.isEmpty == false, let visibleFeed else { return }

        // New mail can change ordering, so the visible list gets a spliced
        // head — never a full re-query, which is the aggressive polling the
        // server cannot afford.
        let merge = await merge(for: visibleFeed)
        await merge.refreshHead()

        for accountKey in outcome.resyncedAccounts {
            logger.notice("\(accountKey, privacy: .public) was re-paged after a stale cursor.")
        }
    }

    /// One delta pass, for a background refresh.
    ///
    /// No paging and no bodies: the point is to learn what changed cheaply,
    /// matching the server's own fifteen-minute poll rather than trying to
    /// beat it.
    public func refreshInBackground() async {
        guard await breaker.isOpen == false else { return }

        do {
            try await breaker.run(attempts: 2) { [self] in
                _ = try await client.session()
            }

            await loadCached()
            _ = await delta.pull(accounts: accounts)
            lastCheckedAt = .now
        } catch {
            logger.error("Background refresh failed: \(error, privacy: .public)")
        }
    }

    /// Called when the network path changes — the one signal worth reopening a
    /// tripped circuit for, since time passing is not evidence of anything.
    public func networkPathChanged() async {
        await breaker.allowRetry()
    }

    /// Loads whatever is cached, then refreshes from the server.
    ///
    /// Cache first and unconditionally: a home server is unreachable often
    /// enough that showing yesterday's mail immediately is the difference
    /// between an app that works on a train and one that doesn't.
    public func start(feed: FeedID) async {
        await loadCached()
        await refresh(feed: feed)
    }

    public func loadCached() async {
        do {
            accounts = try await store.accounts()
            mailboxes = try await allMailboxes()
            publishSharedState()
        } catch {
            logger.error("Could not read the cache: \(error, privacy: .public)")
        }
    }

    /// Hands the widget and the Shortcuts intents a few numbers.
    ///
    /// Written on every cache load rather than on a timer, so it is refreshed
    /// by exactly the things that change it — a sync, a foreground, a delta
    /// pull — and never by anything else.
    private func publishSharedState() {
        // Unread across every inbox, which is what the app's own badge means
        // and therefore what a widget saying "unread" has to agree with.
        let unread =
            mailboxes
            .filter { $0.role == .inbox }
            .reduce(0) { $0 + $1.unreadThreads }

        let total =
            mailboxes
            .filter { $0.role == .inbox }
            .reduce(0) { $0 + $1.totalThreads }

        SharedMailStore.write(
            SharedMailState(unreadCount: unread, totalCount: total, updatedAt: .now))
    }

    /// Re-syncs structure and the first page of `feed`.
    public func refresh(feed: FeedID) async {
        status = .syncing
        defer { if case .syncing = status { status = .idle } }

        do {
            let session = try await client.verify()
            accounts = try await store.syncAccounts(session: session, serverID: serverID)
        } catch JMAPError.notAuthenticated {
            // Never retried and never backed off: a revoked app password stays
            // revoked, and hammering a home server over it helps nobody.
            status = .unauthenticated
            logger.error("Credential rejected by \(self.serverID, privacy: .public)")
            return
        } catch {
            status = .failed(message: describe(error))
            await breaker.recordFailure(error)
            logger.error("Session refresh failed: \(error, privacy: .public)")
            return
        }

        lastCheckedAt = .now
        await breaker.recordSuccess()

        degradedAccounts = [:]
        // Rebuilt on next use: the mailbox ids a role maps to may have moved,
        // and a merge holds those in its pagers' filters.
        merges = [:]
        mergedAccounts = [:]

        // Structure first: a feed for a role cannot be built before the
        // mailbox ids that role maps to in each account are known.
        for account in accounts {
            await syncMailboxes(for: account)
        }

        mailboxes = (try? await allMailboxes()) ?? mailboxes

        // Objects before ordering: a message marked read elsewhere should be
        // right in the list the moment the list is built, rather than one
        // refresh later.
        _ = await delta.pull(accounts: accounts)

        await loadFirstPage(of: feed)
    }

    // MARK: - Whole-list actions

    /// How many messages one "mark all as read" will touch per account.
    ///
    /// `Core/capabilities.maxObjectsInSet` is 500 on plMail, and a single
    /// `Email/set` carrying more than that is refused outright — so this is
    /// the cap, not a guess. A mailbox with more unread than this takes two
    /// presses, which is honest: the undo bar names the number it actually
    /// changed, and one enormous set that the server rejects would change
    /// nothing at all while looking like it had worked.
    public static let bulkLimit = 500

    /// Every unread conversation in `feed`, ready for a bulk action.
    ///
    /// Asked of the server rather than read out of the store, because the
    /// store holds only what has been paged in. "Mark all as read" that
    /// silently meant "mark the first fifty as read" would leave a mailbox
    /// showing unread mail immediately after the user told it not to.
    ///
    /// One query and one get per account, all in a single POST. `Email/get`
    /// is asked only for `threadId`: the ids are what the action needs, and
    /// the thread grouping is what makes the count in the undo bar a count of
    /// conversations rather than of messages.
    public func unreadTargets(in feed: FeedID) async -> [ActionTarget] {
        var calls: [(account: AccountSnapshot, get: CallHandle<EmailGet>)] = []
        var builder: RequestBuilder

        do {
            builder = RequestBuilder(session: try await client.session())
        } catch {
            logger.error("Could not reach the server to count unread: \(error, privacy: .public)")
            return []
        }

        for account in accounts {
            guard let base = await pager(for: feed, account: account)?.baseFilter else {
                continue
            }

            let query = builder.add(
                EmailQuery(
                    accountID: account.accountID,
                    filter: .and([base, .notKeyword(.seen)]),
                    // Every unread *message*, not one per thread: a
                    // conversation with two unread replies has to have both
                    // patched, or it comes back unread the moment the list
                    // refreshes.
                    collapseThreads: false,
                    limit: Self.bulkLimit
                )
            )

            calls.append(
                (
                    account,
                    builder.add(
                        EmailGet(
                            accountID: account.accountID,
                            ids: .reference(query.reference(path: "/ids")),
                            properties: ["id", "threadId"]
                        ))
                ))
        }

        guard calls.isEmpty == false else { return [] }

        let results: MethodResults

        do {
            results = try await client.send(builder)
        } catch {
            logger.error("Could not list unread mail: \(error, privacy: .public)")
            return []
        }

        var targets: [ActionTarget] = []

        for call in calls {
            // Per account, like everything else here: one mailbox refusing
            // must not stop the others being marked read.
            guard let list = try? results.result(of: call.get).list else { continue }

            var byThread: [String: [EmailID]] = [:]

            for email in list {
                byThread[email.threadID?.rawValue ?? email.id.rawValue, default: []]
                    .append(email.id)
            }

            for (threadID, emailIDs) in byThread {
                targets.append(
                    ActionTarget(
                        threadID: threadID,
                        accountKey: call.account.accountKey,
                        accountID: call.account.accountID,
                        emailIDs: emailIDs
                    ))
            }
        }

        return targets
    }

    /// Re-reads mailbox structure, and with it the server's unread counts.
    ///
    /// Called after an action that changes how many unread messages a mailbox
    /// holds. Those counts come from `Mailbox/get` and nothing local
    /// recomputes them, so without this the sidebar goes on claiming five
    /// unread in a list the user has just emptied — the app disagreeing with
    /// itself on the same screen.
    public func refreshStructure() async {
        for account in accounts {
            await syncMailboxes(for: account)
        }

        mailboxes = (try? await allMailboxes()) ?? mailboxes
    }

    // MARK: - Structure

    private func syncMailboxes(for account: AccountSnapshot) async {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let get = builder.add(MailboxGet(accountID: account.accountID))
            // Identities in the same round trip. They used to be fetched only
            // when a composer opened, which had two consequences: the composer
            // waited on a request before it could show who it was sending as,
            // and an account with no name of its own stayed called "Mailbox
            // 1119" in the list until you happened to write a message. Both
            // are fixed by asking here, where the structure is already being
            // read, for no extra round trip.
            let identities = builder.add(IdentityGet(accountID: account.accountID))
            let results = try await client.send(builder)
            let result = try results.result(of: get)

            try await store.replaceMailboxes(
                result.list,
                accountKey: account.accountKey,
                state: result.state
            )

            // Not fatal. A server that refuses `Identity/get` still has a
            // perfectly usable mailbox, and failing the whole structure sync
            // over the sender list would be out of proportion.
            if let identities = try? results.result(of: identities).list {
                try? await store.replaceIdentities(identities, accountKey: account.accountKey)
            }

            try await store.recordSyncSuccess(accountKey: account.accountKey)
        } catch {
            await degrade(account, error: error)
        }
    }

    // MARK: - Feed paging

    /// Brings `feed` up to date and makes sure it has a first screenful.
    public func loadFirstPage(of feed: FeedID) async {
        let merge = await merge(for: feed)

        await merge.refreshHead()
        await merge.loadMore()

        degradedAccounts = await merge.failures
    }

    /// Runs a search, replacing any previous results for the same query.
    ///
    /// Rebuilt rather than refreshed: a search feed's rows are answers to a
    /// question, and re-asking should not splice new answers on top of stale
    /// ones from a query that has since changed.
    public func search(feed: FeedID) async {
        for account in accounts {
            try? await store.resetFeed(feedID: feed.rawValue, accountKey: account.accountKey)
        }

        merges[feed] = nil
        mergedAccounts[feed] = nil

        status = .syncing
        defer { if case .syncing = status { status = .idle } }

        let merge = await merge(for: feed)
        await merge.loadMore()

        degradedAccounts = await merge.failures

        await loadSnippets(for: feed)
    }

    /// Asks the server which part of each result actually matched.
    ///
    /// A separate round trip on purpose: `SearchSnippet/get` needs the ids the
    /// query returned, and there is no back-reference from a query to a
    /// snippet call. It runs after the rows are already on screen, so results
    /// appear at query speed and sharpen a moment later rather than waiting.
    ///
    /// Failure is silent. A snippet is an improvement on the preview the row
    /// already has; a server that does not implement the method — it is
    /// optional in RFC 8621 — should cost nothing but the generic text.
    private func loadSnippets(for feed: FeedID) async {
        guard case .searchResults(let raw) = feed else { return }

        let parsed = SearchQuery.parse(raw)

        let rows = (try? await store.feedRows(feedID: feed.rawValue)) ?? []

        for account in accounts {
            let ids = rows.filter { $0.accountKey == account.accountKey }.map(\.emailID)

            guard ids.isEmpty == false else { continue }

            let accountMailboxes = mailboxes.filter { $0.accountKey == account.accountKey }

            // The same filter the query ran with, built the same way. A
            // different one here would highlight terms the results were never
            // matched on.
            let filter = SearchQueryCompiler.filter(
                for: parsed,
                mailboxID: SearchQueryCompiler.mailboxID(
                    for: parsed, mailboxes: accountMailboxes)
            )

            do {
                var builder = RequestBuilder(session: try await client.session())
                let call = builder.add(
                    SearchSnippetGet(
                        accountID: account.accountID,
                        filter: filter,
                        emailIDs: ids.map { EmailID($0) }
                    )
                )

                let results = try await client.send(builder)

                for snippet in try results.result(of: call).list {
                    guard let html = snippet.preview ?? snippet.subject else { continue }

                    snippets["\(account.accountKey)#\(snippet.emailID.rawValue)"] = html
                }
            } catch {
                logger.debug("No snippets for \(account.accountKey, privacy: .public)")
            }
        }
    }

    /// Drops a search's stored rows.
    ///
    /// Called when a search is abandoned: one materialised feed per query ever
    /// typed would grow without bound, and none of them is worth keeping.
    public func discardSearch(feed: FeedID) async {
        guard case .searchResults = feed else { return }

        snippets.removeAll()

        for account in accounts {
            try? await store.resetFeed(feedID: feed.rawValue, accountKey: account.accountKey)
        }

        merges[feed] = nil
        mergedAccounts[feed] = nil
    }

    /// Extends `feed` by one screenful, interleaved across every account.
    public func loadMore(of feed: FeedID) async {
        let merge = await merge(for: feed)

        await merge.loadMore()

        degradedAccounts = await merge.failures
    }

    /// The merge for a feed, built once and kept.
    ///
    /// Kept rather than rebuilt per call because it holds each account's
    /// buffer: discarding that between scrolls would re-fetch a page per
    /// account every time the list reached its end.
    private func merge(for feed: FeedID) async -> UnifiedFeed {
        if let existing = merges[feed], mergedAccounts[feed] == accountKeys {
            return existing
        }

        let merge = UnifiedFeed(feedID: feed, client: client, store: store)
        var pagers: [AccountPager] = []

        for account in accounts {
            if let pager = await pager(for: feed, account: account) {
                pagers.append(pager)
            }
        }

        await merge.prepare(pagers: pagers)

        merges[feed] = merge
        mergedAccounts[feed] = accountKeys

        return merge
    }

    private var accountKeys: Set<String> { Set(accounts.map(\.accountKey)) }

    /// Builds the filter that selects `feed` within one account.
    ///
    /// Returns nil when the account has no mailbox for that role — a Gmail
    /// account has no Archive binding until one exists, and skipping it is
    /// right where erroring would take down the whole list.
    private func pager(for feed: FeedID, account: AccountSnapshot) async -> AccountPager? {
        let filter: EmailFilter?

        switch feed {
        case .unified(let role):
            guard
                let mailboxID = try? await store.mailbox(
                    role: role, accountKey: account.accountKey)
            else { return nil }

            filter = .inMailbox(mailboxID)

        case .unifiedLabel(let labelID):
            let matching = mailboxes.first {
                $0.accountKey == account.accountKey && $0.labelID == labelID
            }

            guard let matching else { return nil }

            filter = .inMailbox(matching.mailboxID)

        case .mailbox(let accountKey, let mailboxID):
            guard accountKey == account.accountKey else { return nil }

            filter = .inMailbox(mailboxID)

        case .searchResults(let raw):
            let parsed = SearchQuery.parse(raw)
            let accountMailboxes = mailboxes.filter { $0.accountKey == account.accountKey }

            // An account with no mailbox for the requested role cannot answer
            // this query, and including it unfiltered would return its whole
            // mailbox as "results".
            guard SearchQueryCompiler.canSearch(parsed, mailboxes: accountMailboxes) else {
                return nil
            }

            filter = SearchQueryCompiler.filter(
                for: parsed,
                mailboxID: SearchQueryCompiler.mailboxID(
                    for: parsed, mailboxes: accountMailboxes)
            )

            // A query that narrows nothing would page the entire account.
            guard filter != nil else { return nil }
        }

        return AccountPager(
            accountKey: account.accountKey,
            accountID: account.accountID,
            baseFilter: filter
        )
    }

    // MARK: - Failure

    private func degrade(_ account: AccountSnapshot, error: any Error) async {
        let message = describe(error)
        degradedAccounts[account.accountKey] = message
        try? await store.recordSyncFailure(message, accountKey: account.accountKey)
        logger.error("\(account.name, privacy: .public) failed: \(error, privacy: .public)")
    }

    private func allMailboxes() async throws -> [MailboxSnapshot] {
        var all: [MailboxSnapshot] = []

        for account in accounts {
            all += try await store.mailboxes(accountKey: account.accountKey)
        }

        return all
    }

    /// Messages name the cause and the host. Users self-host: when the server
    /// is down they are the one who has to go and fix it, and the hostname is
    /// genuinely the useful part.
    private func describe(_ error: any Error) -> String {
        guard let error = error as? JMAPError else { return error.localizedDescription }

        switch error {
        case .notAuthenticated:
            return String(
                localized: "Your app password was revoked or is no longer valid.", bundle: .module)
        case .unreachable(let host, _):
            return String(localized: "Can't reach \(host).", bundle: .module)
        case .untrustedCertificate(let host, _):
            return "\(host) presented a certificate that no longer matches the one you trusted."
        case .methodFailed(let type, let description, _):
            // Raw JMAP error types are for the log, never for a person.
            logger.error("Method error \(type.rawValue, privacy: .public): \(description ?? "")")
            return String(localized: "The server couldn't complete that request.", bundle: .module)
        default:
            logger.error("Unexpected: \(error, privacy: .public)")
            return String(
                localized: "Something went wrong talking to \(connection.host).", bundle: .module)
        }
    }
}
