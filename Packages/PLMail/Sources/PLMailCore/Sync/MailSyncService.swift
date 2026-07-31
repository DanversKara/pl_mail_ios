import Foundation
import JMAPKit
import OSLog
import Observation

/// Drives syncing for the connected server.
///
/// Phase-4 scope: accounts, mailboxes, and paging one feed per account. The
/// k-way merge that turns several accounts into one ordered list, and delta
/// sync through `Email/changes`, build on this rather than replacing it — an
/// ``AccountPager`` per account is already the shape the merge needs.
@MainActor
@Observable
public final class MailSyncService {
    public enum Status: Equatable, Sendable {
        case idle
        case syncing
        /// Reachable again after a failure, or never failed.
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
        } catch {
            status = .failed(message: describe(error))
            logger.error("Session refresh failed: \(error, privacy: .public)")
            return
        }

        degradedAccounts = [:]

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

    public func loadFirstPage(of feed: FeedID) async {
        for account in accounts {
            guard let pager = await pager(for: feed, account: account) else { continue }

            do {
                let page = try await pager.page(after: FeedCursorSnapshot(), using: client)

                try await store.upsert(
                    emails: page.emails,
                    threads: page.threads,
                    accountKey: account.accountKey,
                    emailState: page.emailState
                )
                // Replace rather than append: this is page one, and a thread
                // that has since moved out of the mailbox must not linger.
                try await store.replaceFeedSlice(
                    page.rows,
                    feedID: feed.rawValue,
                    accountKey: account.accountKey,
                    cursor: page.cursor
                )
            } catch {
                await degrade(account, error: error)
            }
        }
    }

    /// Fetches the next page for every account that has one.
    public func loadMore(of feed: FeedID) async {
        for account in accounts {
            guard let pager = await pager(for: feed, account: account) else { continue }

            do {
                let cursor = try await store.cursor(
                    feedID: feed.rawValue, accountKey: account.accountKey)

                guard cursor.isExhausted == false else { continue }

                let page = try await pager.page(after: cursor, using: client)

                guard page.rows.isEmpty == false || page.cursor.isExhausted else { continue }

                try await store.upsert(
                    emails: page.emails,
                    threads: page.threads,
                    accountKey: account.accountKey,
                    emailState: page.emailState
                )
                try await store.appendFeedRows(
                    page.rows,
                    feedID: feed.rawValue,
                    accountKey: account.accountKey,
                    cursor: page.cursor
                )
            } catch {
                await degrade(account, error: error)
            }
        }
    }

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
