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

    /// One merge per feed, so each keeps its own buffers and cursors.
    private var merges: [FeedID: UnifiedFeed] = [:]
    /// Which accounts each merge was built for. A change means it has to be
    /// rebuilt — an account added or removed changes what is being merged.
    private var mergedAccounts: [FeedID: Set<String>] = [:]

    private let connection: ServerConnection
    private let client: JMAPClient
    private let store: SyncStore
    private let logger = Logger(subsystem: "de.plmail", category: "sync")

    public init(connection: ServerConnection, store: SyncStore) {
        self.connection = connection
        self.client = connection.makeClient()
        self.store = store
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
        } catch {
            logger.error("Could not read the cache: \(error, privacy: .public)")
        }
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
            logger.error("Session refresh failed: \(error, privacy: .public)")
            return
        }

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

        await loadFirstPage(of: feed)
    }

    // MARK: - Structure

    private func syncMailboxes(for account: AccountSnapshot) async {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let get = builder.add(MailboxGet(accountID: account.accountID))
            let results = try await client.send(builder)
            let result = try results.result(of: get)

            try await store.replaceMailboxes(
                result.list,
                accountKey: account.accountKey,
                state: result.state
            )
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
    }

    /// Drops a search's stored rows.
    ///
    /// Called when a search is abandoned: one materialised feed per query ever
    /// typed would grow without bound, and none of them is worth keeping.
    public func discardSearch(feed: FeedID) async {
        guard case .searchResults = feed else { return }

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
            return "Your app password was revoked or is no longer valid."
        case .unreachable(let host, _):
            return "Can't reach \(host)."
        case .untrustedCertificate(let host, _):
            return "\(host) presented a certificate that no longer matches the one you trusted."
        case .methodFailed(let type, let description, _):
            // Raw JMAP error types are for the log, never for a person.
            logger.error("Method error \(type.rawValue, privacy: .public): \(description ?? "")")
            return "The server couldn't complete that request."
        default:
            logger.error("Unexpected: \(error, privacy: .public)")
            return "Something went wrong talking to \(connection.host)."
        }
    }
}
