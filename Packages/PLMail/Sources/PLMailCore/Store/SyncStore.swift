import Foundation
import JMAPKit
import SwiftData

/// The only thing that writes to the store.
///
/// A `@ModelActor`, so it owns a background context and the UI's `@Query` on
/// the main context stays responsive while a sync runs. SwiftData propagates
/// saves from here to the main context, `@Query` re-runs, and SwiftUI diffs.
///
/// Saves are batched per sync unit rather than per object: a page of fifty
/// emails is one save, not fifty.
@ModelActor
public actor SyncStore {
    // MARK: - Accounts

    /// Reconciles the account list with what the Session reports.
    ///
    /// Accounts the server no longer lists are removed along with everything
    /// they own — a disconnected mailbox should not leave a ghost in the
    /// sidebar.
    @discardableResult
    public func syncAccounts(session: Session, serverID: String) throws -> [AccountSnapshot] {
        let ordered = session.orderedAccounts
        var live: Set<String> = []

        for (index, entry) in ordered.enumerated() {
            let key = StoreKey.account(server: serverID, account: entry.id)
            live.insert(key)

            let account =
                try account(key) ?? insertAccount(key: key, serverID: serverID, id: entry.id)
            account.name = entry.account.name
            account.isPersonal = entry.account.isPersonal
            account.isReadOnly = entry.account.isReadOnly
            account.sortIndex = index
        }

        for stale in try allAccounts() where live.contains(stale.uid) == false {
            try deleteEverything(forAccountKey: stale.uid)
            modelContext.delete(stale)
        }

        try modelContext.save()

        return try allAccounts()
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(snapshot(of:))
    }

    public func accounts() throws -> [AccountSnapshot] {
        try allAccounts()
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(snapshot(of:))
    }

    public func recordSyncFailure(_ message: String?, accountKey: String) throws {
        guard let account = try account(accountKey) else { return }
        account.lastSyncError = message
        try modelContext.save()
    }

    public func recordSyncSuccess(accountKey: String) throws {
        guard let account = try account(accountKey) else { return }
        account.lastSyncedAt = .now
        account.lastSyncError = nil
        try modelContext.save()
    }

    // MARK: - Mailboxes

    @discardableResult
    public func replaceMailboxes(
        _ mailboxes: [Mailbox],
        accountKey: String,
        state: StateToken
    ) throws -> [MailboxSnapshot] {
        var live: Set<String> = []

        for mailbox in mailboxes {
            let uid = StoreKey.object(accountKey: accountKey, id: mailbox.id.rawValue)
            live.insert(uid)

            let stored =
                try existing(StoredMailbox.self, uid: uid)
                ?? {
                    let new = StoredMailbox(
                        uid: uid, accountKey: accountKey, mailboxID: mailbox.id.rawValue,
                        name: mailbox.name ?? "")
                    modelContext.insert(new)
                    return new
                }()

            stored.labelID = mailbox.labelID?.rawValue
            stored.name = mailbox.name ?? stored.name
            stored.parentID = mailbox.parentID?.rawValue
            stored.role = mailbox.role?.rawValue
            stored.sortOrder = mailbox.sortOrder ?? 0
            stored.totalEmails = mailbox.totalEmails ?? 0
            stored.unreadEmails = mailbox.unreadEmails ?? 0
            stored.totalThreads = mailbox.totalThreads ?? 0
            stored.unreadThreads = mailbox.unreadThreads ?? 0
            stored.isSubscribed = mailbox.isSubscribed ?? true
            stored.mayRename = mailbox.myRights?.mayRename ?? false
            stored.mayDelete = mailbox.myRights?.mayDelete ?? false
        }

        for stale in try mailboxRows(accountKey: accountKey)
        where live.contains(stale.uid) == false {
            modelContext.delete(stale)
        }

        if let account = try account(accountKey) {
            account.mailboxState = state.rawValue
        }

        try modelContext.save()

        return try mailboxRows(accountKey: accountKey).map(snapshot(of:))
    }

    public func mailbox(role: MailboxRole, accountKey: String) throws -> MailboxID? {
        let wanted = role.rawValue

        return try mailboxRows(accountKey: accountKey)
            .first { $0.role == wanted }
            .map { MailboxID($0.mailboxID) }
    }

    public func mailboxes(accountKey: String) throws -> [MailboxSnapshot] {
        try mailboxRows(accountKey: accountKey).map(snapshot(of:))
    }

    // MARK: - Emails and threads

    /// Writes a page of emails and the threads they belong to.
    ///
    /// - Parameters:
    ///   - emails: The page's emails, in the order they should appear.
    ///   - threads: `Thread/get` results for the same page, which carry the
    ///     full email-id list per thread. Fetched in the same round trip via a
    ///     chained back-reference, so the message count on a row is correct
    ///     without an extra request.
    ///   - accountKey: Which account these belong to.
    ///   - emailState: The state token to resume `Email/changes` from, if the
    ///     caller has one.
    /// - Throws: Whatever the underlying `ModelContext` save throws.
    public func upsert(
        emails: [Email],
        threads: [MailThread],
        accountKey: String,
        emailState: StateToken?
    ) throws {
        var threadEmailIDs: [String: [String]] = [:]

        for thread in threads {
            threadEmailIDs[thread.id.rawValue] = thread.emailIDs.map(\.rawValue)
        }

        for email in emails {
            let stored = try upsertEmail(email, accountKey: accountKey)

            guard let threadID = stored.threadID else { continue }

            try updateThread(
                threadID,
                accountKey: accountKey,
                from: stored,
                emailIDs: threadEmailIDs[threadID]
            )
        }

        if let emailState, let account = try account(accountKey) {
            account.emailState = emailState.rawValue
        }

        try modelContext.save()
    }

    @discardableResult
    private func upsertEmail(_ email: Email, accountKey: String) throws -> StoredEmail {
        let uid = StoreKey.object(accountKey: accountKey, id: email.id.rawValue)

        let stored =
            try existing(StoredEmail.self, uid: uid)
            ?? {
                let new = StoredEmail(uid: uid, accountKey: accountKey, emailID: email.id.rawValue)
                modelContext.insert(new)
                return new
            }()

        // Every property is applied only when the response carried it: a
        // narrowed `properties` request is the normal case, and overwriting a
        // cached subject with nil because this call didn't ask for it would
        // make the list flicker empty on every refresh.
        if let threadID = email.threadID { stored.threadID = threadID.rawValue }
        if let blobID = email.blobID { stored.blobID = blobID.rawValue }
        if let receivedAt = email.receivedAt { stored.receivedAt = receivedAt.date }
        if let sentAt = email.sentAt { stored.sentAt = sentAt.date }
        if let subject = email.subject { stored.subject = subject }
        if let preview = email.preview { stored.preview = preview }
        if let size = email.size { stored.size = size }
        if let hasAttachment = email.hasAttachment { stored.hasAttachment = hasAttachment }

        if let from = email.from?.first {
            stored.fromName = from.name
            stored.fromAddress = from.email
        }

        if let to = email.to { stored.toJSON = try? JSONEncoder().encode(to) }
        if let cc = email.cc { stored.ccJSON = try? JSONEncoder().encode(cc) }
        if let bcc = email.bcc { stored.bccJSON = try? JSONEncoder().encode(bcc) }

        if let keywords = email.keywords {
            stored.isSeen = keywords.contains(.seen)
            stored.isFlagged = keywords.contains(.flagged)
            stored.isDraft = keywords.contains(.draft)
            stored.isAnswered = keywords.contains(.answered)
        }

        if let mailboxIDs = email.mailboxIDs {
            stored.mailboxIDs = mailboxIDs.elements.map(\.rawValue).sorted()
        }

        return stored
    }

    private func updateThread(
        _ threadID: String,
        accountKey: String,
        from email: StoredEmail,
        emailIDs: [String]?
    ) throws {
        let uid = StoreKey.object(accountKey: accountKey, id: threadID)

        let thread =
            try existing(StoredThread.self, uid: uid)
            ?? {
                let new = StoredThread(uid: uid, accountKey: accountKey, threadID: threadID)
                modelContext.insert(new)
                return new
            }()

        if let emailIDs {
            thread.emailIDs = emailIDs
            thread.messageCount = emailIDs.count
        } else if thread.emailIDs.contains(email.emailID) == false {
            thread.emailIDs.append(email.emailID)
            thread.messageCount = thread.emailIDs.count
        }

        // The row renders from the newest message, so older ones arriving
        // later must not overwrite it.
        let incoming = email.receivedAt ?? .distantPast

        guard incoming >= thread.latestReceivedAt else { return }

        thread.latestReceivedAt = incoming
        thread.subject = email.subject
        thread.snippet = email.preview
        thread.hasAttachment = email.hasAttachment
        thread.isFlagged = email.isFlagged
        thread.isUnread = email.isSeen == false

        // Participants should be everyone who has written, oldest first — the
        // web UI is deliberate about that, because using the newest sender
        // made every thread you had answered look like it came from you.
        // Until the reader fetches whole threads, this is the newest sender,
        // which is right for the single-message threads that dominate a list.
        thread.participantsSummary = email.fromName ?? email.fromAddress ?? ""
    }

    // MARK: - Feed

    /// Replaces one account's slice of a feed with a freshly-paged prefix.
    public func replaceFeedSlice(
        _ rows: [FeedRow],
        feedID: String,
        accountKey: String,
        cursor: FeedCursorSnapshot
    ) throws {
        for stale in try feedEntries(feedID: feedID, accountKey: accountKey) {
            modelContext.delete(stale)
        }

        try appendFeedRows(rows, feedID: feedID, accountKey: accountKey, cursor: cursor)
    }

    /// Adds a page to the end of a feed.
    public func appendFeedRows(
        _ rows: [FeedRow],
        feedID: String,
        accountKey: String,
        cursor: FeedCursorSnapshot
    ) throws {
        for row in rows {
            let uid = "\(feedID)#\(accountKey)#\(row.threadID)"

            // A thread can be pushed into a later page by new mail arriving,
            // so the same thread can be paged twice. Updating rather than
            // inserting is what keeps it from appearing twice in the list.
            if let existing = try existing(StoredFeedEntry.self, uid: uid) {
                existing.sortDate = row.sortDate
                existing.emailID = row.emailID
                continue
            }

            modelContext.insert(
                StoredFeedEntry(
                    uid: uid,
                    feedID: feedID,
                    sortDate: row.sortDate,
                    accountKey: accountKey,
                    threadID: row.threadID,
                    emailID: row.emailID
                )
            )
        }

        try store(cursor, feedID: feedID, accountKey: accountKey)
        try modelContext.save()
    }

    public func cursor(feedID: String, accountKey: String) throws -> FeedCursorSnapshot {
        let uid = "\(feedID)#\(accountKey)"

        guard let stored = try existing(StoredFeedCursor.self, uid: uid) else {
            return FeedCursorSnapshot()
        }

        return FeedCursorSnapshot(
            lastSortDate: stored.lastSortDate,
            boundaryIDs: Set(stored.boundaryIDs),
            isExhausted: stored.isExhausted
        )
    }

    private func store(
        _ cursor: FeedCursorSnapshot,
        feedID: String,
        accountKey: String
    ) throws {
        let uid = "\(feedID)#\(accountKey)"

        let stored =
            try existing(StoredFeedCursor.self, uid: uid)
            ?? {
                let new = StoredFeedCursor(uid: uid, feedID: feedID, accountKey: accountKey)
                modelContext.insert(new)
                return new
            }()

        stored.lastSortDate = cursor.lastSortDate
        stored.boundaryIDs = Array(cursor.boundaryIDs)
        stored.isExhausted = cursor.isExhausted
    }

    // MARK: - Deletion

    public func deleteEverything() throws {
        for type in SchemaV1.models {
            try modelContext.delete(model: type)
        }
        try modelContext.save()
    }

    private func deleteEverything(forAccountKey accountKey: String) throws {
        try modelContext.delete(
            model: StoredMailbox.self,
            where: #Predicate { $0.accountKey == accountKey })
        try modelContext.delete(
            model: StoredThread.self, where: #Predicate { $0.accountKey == accountKey })
        try modelContext.delete(
            model: StoredEmail.self, where: #Predicate { $0.accountKey == accountKey })
        try modelContext.delete(
            model: StoredFeedEntry.self,
            where: #Predicate { $0.accountKey == accountKey })
        try modelContext.delete(
            model: StoredFeedCursor.self,
            where: #Predicate { $0.accountKey == accountKey })
        try modelContext.delete(
            model: StoredIdentity.self,
            where: #Predicate { $0.accountKey == accountKey })
    }

    // MARK: - Fetch helpers

    private func account(_ key: String) throws -> StoredAccount? {
        try existing(StoredAccount.self, uid: key)
    }

    private func insertAccount(
        key: String, serverID: String, id: AccountID
    ) -> StoredAccount {
        let account = StoredAccount(
            uid: key, serverID: serverID, accountID: id.rawValue, name: "")
        modelContext.insert(account)
        return account
    }

    private func allAccounts() throws -> [StoredAccount] {
        try modelContext.fetch(FetchDescriptor<StoredAccount>())
    }

    // Written out per type rather than generically: `#Predicate` is translated
    // into a query at compile time, so it cannot go through a protocol or a
    // dynamic key path. One-line functions are the honest way to say that.

    private func first<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>
    ) throws -> T? {
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func existing(_ type: StoredAccount.Type, uid: String) throws -> StoredAccount? {
        try first(FetchDescriptor<StoredAccount>(predicate: #Predicate { $0.uid == uid }))
    }

    private func existing(_ type: StoredMailbox.Type, uid: String) throws -> StoredMailbox? {
        try first(FetchDescriptor<StoredMailbox>(predicate: #Predicate { $0.uid == uid }))
    }

    private func existing(_ type: StoredEmail.Type, uid: String) throws -> StoredEmail? {
        try first(FetchDescriptor<StoredEmail>(predicate: #Predicate { $0.uid == uid }))
    }

    private func existing(_ type: StoredThread.Type, uid: String) throws -> StoredThread? {
        try first(FetchDescriptor<StoredThread>(predicate: #Predicate { $0.uid == uid }))
    }

    private func existing(_ type: StoredFeedEntry.Type, uid: String) throws -> StoredFeedEntry? {
        try first(FetchDescriptor<StoredFeedEntry>(predicate: #Predicate { $0.uid == uid }))
    }

    private func existing(_ type: StoredFeedCursor.Type, uid: String) throws -> StoredFeedCursor? {
        try first(FetchDescriptor<StoredFeedCursor>(predicate: #Predicate { $0.uid == uid }))
    }

    private func mailboxRows(accountKey: String) throws -> [StoredMailbox] {
        try modelContext.fetch(
            FetchDescriptor<StoredMailbox>(
                predicate: #Predicate { $0.accountKey == accountKey },
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
            )
        )
    }

    private func feedEntries(feedID: String, accountKey: String) throws -> [StoredFeedEntry] {
        try modelContext.fetch(
            FetchDescriptor<StoredFeedEntry>(
                predicate: #Predicate { $0.feedID == feedID && $0.accountKey == accountKey }
            )
        )
    }

    // MARK: - Snapshots

    private func snapshot(of account: StoredAccount) -> AccountSnapshot {
        AccountSnapshot(
            accountKey: account.uid,
            accountID: AccountID(account.accountID),
            name: account.name,
            emailState: account.emailState.map(StateToken.init(rawValue:)),
            threadState: account.threadState.map(StateToken.init(rawValue:)),
            mailboxState: account.mailboxState.map(StateToken.init(rawValue:))
        )
    }

    private func snapshot(of mailbox: StoredMailbox) -> MailboxSnapshot {
        MailboxSnapshot(
            accountKey: mailbox.accountKey,
            mailboxID: MailboxID(mailbox.mailboxID),
            labelID: mailbox.labelID.map { LabelID(rawValue: $0) },
            name: mailbox.name,
            role: mailbox.role.map(MailboxRole.init(rawValue:)),
            unreadThreads: mailbox.unreadThreads,
            totalThreads: mailbox.totalThreads
        )
    }
}

/// One row of a paged list, before it becomes a `StoredFeedEntry`.
public struct FeedRow: Hashable, Sendable {
    public var threadID: String
    public var emailID: String
    public var sortDate: Date

    public init(threadID: String, emailID: String, sortDate: Date) {
        self.threadID = threadID
        self.emailID = emailID
        self.sortDate = sortDate
    }
}
