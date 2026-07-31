import Foundation
import JMAPKit
import OSLog
import Observation

/// Loads one conversation and keeps its read state honest.
@MainActor
@Observable
public final class ThreadLoader {
    public private(set) var messages: [MessageSnapshot] = []
    /// When this conversation is due back, if it is snoozed. Read from the
    /// store rather than tracked here, so the reader agrees with the row that
    /// opened it.
    public private(set) var snoozedUntil: Date?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let threadID: String
    private let accountKey: String
    private let accountID: AccountID
    private let client: JMAPClient
    private let store: SyncStore
    private let logger = Logger(subsystem: "de.plmail", category: "reader")

    public init(
        threadID: String,
        accountKey: String,
        accountID: AccountID,
        client: JMAPClient,
        store: SyncStore
    ) {
        self.threadID = threadID
        self.accountKey = accountKey
        self.accountID = accountID
        self.client = client
        self.store = store
    }

    /// Shows what is cached, then fetches the rest.
    public func load() async {
        await readCache()

        isLoading = true
        defer { isLoading = false }

        do {
            try await fetch()
            await readCache()
            errorMessage = nil
        } catch {
            // Cached messages stay on screen: a thread you have already read
            // should still be readable on a train.
            errorMessage = describe(error)
            logger.error("Thread \(self.threadID, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func readCache() async {
        messages = (try? await store.messages(threadID: threadID, accountKey: accountKey)) ?? []
        snoozedUntil = try? await store.snoozedUntil(
            threadID: threadID, accountKey: accountKey)
    }

    /// One round trip: the thread's message ids, then those messages with
    /// their bodies, paired by back-reference.
    private func fetch() async throws {
        let session = try await client.session()
        var builder = RequestBuilder(session: session)

        let thread = builder.add(
            ThreadGet(accountID: accountID, ids: .value([ThreadID(threadID)])))

        let emails = builder.add(
            EmailGet(
                accountID: accountID,
                ids: .reference(thread.reference(path: "/list/*/emailIds")),
                properties: EmailGet.readerProperties,
                fetchTextBodyValues: true,
                fetchHTMLBodyValues: true,
                // Enough for any mail a person will read; a message larger
                // than this is a document, and truncating beats spending a
                // home uplink's whole budget on one newsletter.
                maxBodyValueBytes: 1_000_000
            )
        )

        let results = try await client.send(builder)
        let threads = try results.result(of: thread).list
        let list = try results.result(of: emails).list

        try await store.upsert(
            emails: list, threads: threads, accountKey: accountKey, emailState: nil)
        try await store.storeReaderContent(list, accountKey: accountKey)
    }

    // MARK: - Read state

    /// Marks the thread read.
    ///
    /// Called once the thread has actually been shown, never on prefetch —
    /// marking mail read because it scrolled past in a list is how a client
    /// loses someone's place.
    ///
    /// This is the one write v1 makes. Applied locally first so the row
    /// updates immediately, then sent; the server routes it through the same
    /// propagator the web UI uses, so it reaches Gmail/IMAP/Graph identically.
    public func markRead() async {
        let unread = messages.filter { $0.isSeen == false }.map(\.emailID)

        guard unread.isEmpty == false else { return }

        try? await store.setSeen(true, emailIDs: unread, accountKey: accountKey)
        await readCache()

        do {
            var builder = RequestBuilder(session: try await client.session())
            builder.add(
                EmailSetKeywords(
                    accountID: accountID,
                    ids: unread.map { EmailID(rawValue: $0) },
                    isSeen: true
                )
            )

            _ = try await client.send(builder)
        } catch {
            // Left applied locally rather than reverted: the next sync's
            // Email/changes will correct it either way, and flipping the row
            // back under the reader's eyes is worse than being briefly ahead
            // of the server.
            logger.error("Marking read failed: \(error, privacy: .public)")
        }
    }

    private func describe(_ error: any Error) -> String {
        guard let error = error as? JMAPError else { return error.localizedDescription }

        return switch error {
        case .notAuthenticated: "Your app password is no longer valid."
        case .unreachable(let host, _): "Can't reach \(host)."
        default: "This conversation couldn't be loaded."
        }
    }
}
