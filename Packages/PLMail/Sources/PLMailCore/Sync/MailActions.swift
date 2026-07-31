import Foundation
import JMAPKit
import OSLog
import Observation

/// Archive, trash, star, mark read — and undo.
///
/// Every one applies to the local store first and is sent afterwards. The
/// server propagates outward asynchronously anyway, so waiting for a round
/// trip before moving a row would make the app feel slower than the web UI for
/// no gain in correctness.
///
/// Every one is also undoable, because the alternative is an app that
/// permanently loses mail to a mis-swipe.
@MainActor
@Observable
public final class MailActions {
    /// What the user just did, and how to take it back.
    public struct Undoable: Identifiable, Sendable {
        public let id = UUID()
        public let message: String
        let undo: @MainActor @Sendable () async -> Void
    }

    /// The most recent action, while it can still be taken back.
    public private(set) var pending: Undoable?

    /// An action the server refused.
    ///
    /// Surfaced rather than logged: the row was already moved optimistically,
    /// so a rejection the user is not told about is the app and the server
    /// quietly disagreeing about where their mail is.
    public private(set) var failure: String?

    private let client: JMAPClient
    private let store: SyncStore
    private let logger = Logger(subsystem: "de.plmail", category: "actions")
    private var dismissal: Task<Void, Never>?

    /// How long an undo stays offered. Long enough to notice a mistake, short
    /// enough not to hover over the next thing being read.
    private let undoWindow: Duration = .seconds(6)

    public init(client: JMAPClient, store: SyncStore) {
        self.client = client
        self.store = store
    }

    // MARK: - Actions

    /// Archives a thread: removes it from the Inbox, and nothing else.
    ///
    /// "Archived" here means *carries no Inbox label*. Adding an Archive label
    /// instead would leave it in the inbox as well, which is not what anyone
    /// means by archiving.
    public func archive(_ target: ActionTarget) async {
        guard let inbox = try? await store.mailbox(role: .inbox, accountKey: target.accountKey)
        else { return }

        // Joined in the same patch as leaving the Inbox: a message must belong
        // to at least one mailbox, and most inbox mail belongs to no other.
        let archive = try? await store.mailbox(role: .archive, accountKey: target.accountKey)

        await apply(
            target,
            localChange: {
                try await $0.removeFromFeeds(target.threadID, accountKey: target.accountKey)
            },
            request: EmailSet.archive(
                ids: target.emailIDs, inbox: inbox, archive: archive,
                accountID: target.accountID),
            undoMessage: "Archived",
            undoRequest: EmailSet.moveToInbox(
                ids: target.emailIDs, inbox: inbox, leaving: archive,
                accountID: target.accountID)
        )
    }

    /// Moves a thread to Trash.
    ///
    /// Presented as Trash rather than Delete because that is what it is: the
    /// server has no hard-delete path, and the mail is still on the provider.
    public func trash(_ target: ActionTarget) async {
        guard let inbox = try? await store.mailbox(role: .inbox, accountKey: target.accountKey)
        else { return }

        await apply(
            target,
            localChange: {
                try await $0.removeFromFeeds(target.threadID, accountKey: target.accountKey)
            },
            request: EmailSet.trash(ids: target.emailIDs, accountID: target.accountID),
            undoMessage: "Moved to Trash",
            // Undoing a trash puts it back in the Inbox: the destroy moved it
            // out of every mailbox it was in, and the inbox is where the user
            // was looking at it.
            undoRequest: EmailSet.moveToInbox(
                ids: target.emailIDs, inbox: inbox, accountID: target.accountID)
        )
    }

    public func setFlagged(_ isFlagged: Bool, _ target: ActionTarget) async {
        await apply(
            target,
            localChange: {
                try await $0.setFlagged(
                    isFlagged,
                    emailIDs: target.emailIDs.map(\.rawValue),
                    accountKey: target.accountKey)
                return []
            },
            request: EmailSet.setFlagged(
                isFlagged, ids: target.emailIDs, accountID: target.accountID),
            undoMessage: isFlagged ? "Starred" : "Unstarred",
            undoRequest: EmailSet.setFlagged(
                isFlagged == false, ids: target.emailIDs, accountID: target.accountID)
        )
    }

    public func setSeen(_ isSeen: Bool, _ target: ActionTarget) async {
        await apply(
            target,
            localChange: {
                try await $0.setSeen(
                    isSeen,
                    emailIDs: target.emailIDs.map(\.rawValue),
                    accountKey: target.accountKey)
                return []
            },
            request: EmailSet.setSeen(isSeen, ids: target.emailIDs, accountID: target.accountID),
            undoMessage: isSeen ? "Marked read" : "Marked unread",
            undoRequest: EmailSet.setSeen(
                isSeen == false, ids: target.emailIDs, accountID: target.accountID)
        )
    }

    /// Applies or removes a label across every message in a conversation.
    ///
    /// The whole thread, like every other action here: labelling one reply and
    /// not the rest is not something anyone means from a conversation list.
    ///
    /// The label's name is passed in rather than looked up so the undo bar can
    /// say which one — "Labelled Work" tells you what to undo; "Labelled" does
    /// not.
    public func setLabel(
        _ isApplied: Bool, mailbox: MailboxID, named name: String, _ target: ActionTarget
    ) async {
        await apply(
            target,
            localChange: {
                try await $0.setMailbox(
                    isApplied,
                    mailboxID: mailbox.rawValue,
                    emailIDs: target.emailIDs.map(\.rawValue),
                    accountKey: target.accountKey)
                return []
            },
            request: EmailSet.setLabel(
                isApplied, mailbox: mailbox, ids: target.emailIDs, accountID: target.accountID),
            undoMessage: isApplied ? "Labelled \(name)" : "Removed \(name)",
            undoRequest: EmailSet.setLabel(
                isApplied == false, mailbox: mailbox, ids: target.emailIDs,
                accountID: target.accountID)
        )
    }

    // MARK: - Undo

    public func undo() async {
        guard let pending else { return }

        self.pending = nil
        dismissal?.cancel()

        await pending.undo()
    }

    public func dismissUndo() {
        pending = nil
        dismissal?.cancel()
    }

    // MARK: - Machinery

    private func apply(
        _ target: ActionTarget,
        localChange: @Sendable (SyncStore) async throws -> [RemovedFeedRow],
        request: EmailSet,
        undoMessage: String,
        undoRequest: EmailSet
    ) async {
        failure = nil
        // Kept so a refusal can put the row back exactly where it was, rather
        // than re-paging the list and moving the reader's place.
        let removedRows = (try? await localChange(store)) ?? []

        offerUndo(undoMessage) { [weak self] in
            guard let self else { return }

            // The undo re-fetches rather than reversing the local edit: the
            // server is the authority on where a message ended up, and a
            // guessed reversal would drift from it.
            _ = await send(undoRequest, target: target)
            await refetch(target)
        }

        guard await send(request, target: target) else {
            // The optimistic move has to be taken back. Leaving it would show
            // a message as archived that is still in the inbox on every other
            // device — divergence the user has no way to notice.
            dismissUndo()
            try? await store.restoreFeedRows(removedRows)
            await refetch(target)
            return
        }
    }

    /// - Returns: Whether the server accepted the change.
    @discardableResult
    private func send(_ request: EmailSet, target: ActionTarget) async -> Bool {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(request)
            let results = try await client.send(builder)

            if let error = results.failure(of: call) { throw error }

            let result = try results.result(of: call)

            // A 200 is not success: Email/set reports per-object refusals in
            // notUpdated, and treating the call's status as the answer is how
            // a rejected change looks like an applied one.
            if let refused = result.notUpdated, refused.isEmpty == false {
                failure = Self.describe(refused)
                logger.error("Rejected: \(String(describing: refused), privacy: .public)")
                return false
            }

            if let refused = result.notDestroyed, refused.isEmpty == false {
                failure = Self.describe(refused)
                logger.error("Refused destroy: \(String(describing: refused), privacy: .public)")
                return false
            }

            return true
        } catch {
            failure = "Couldn't reach the server. Nothing was changed."
            logger.error("Action failed: \(error, privacy: .public)")
            return false
        }
    }

    /// Turns a per-object refusal into something a person can act on.
    private static func describe(_ refusals: [EmailID: JSONValue]) -> String {
        let type =
            refusals.values
            .compactMap { $0.objectValue?["type"]?.stringValue }
            .first

        return switch type {
        case "invalidProperties":
            // Almost always one rule: a message must be in at least one
            // mailbox. Archiving hits it when the account has no Archive
            // binding to move to, and removing a label hits it when that label
            // was the last one. Both leave the message nowhere, so the copy
            // names the rule rather than guessing which of the two it was.
            "A message has to stay in at least one label, and that was the last one."
        case "forbidden", "accountReadOnly":
            "This account is read-only."
        default:
            "The server didn't accept that change."
        }
    }

    public func dismissFailure() {
        failure = nil
    }

    /// Pulls the thread back so an undone action shows the server's version.
    private func refetch(_ target: ActionTarget) async {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let get = builder.add(
                EmailGet(
                    accountID: target.accountID,
                    ids: .value(target.emailIDs),
                    properties: EmailGet.listRowProperties
                )
            )
            let threads = builder.add(
                ThreadGet(
                    accountID: target.accountID,
                    ids: .reference(get.reference(path: "/list/*/threadId"))
                )
            )

            let results = try await client.send(builder)

            try await store.upsert(
                emails: try results.result(of: get).list,
                threads: try results.result(of: threads).list,
                accountKey: target.accountKey,
                emailState: nil
            )
        } catch {
            logger.error("Could not refetch after undo: \(error, privacy: .public)")
        }
    }

    private func offerUndo(
        _ message: String, _ undo: @escaping @MainActor @Sendable () async -> Void
    ) {
        dismissal?.cancel()
        pending = Undoable(message: message, undo: undo)

        dismissal = Task { [undoWindow] in
            try? await Task.sleep(for: undoWindow)

            guard Task.isCancelled == false else { return }

            pending = nil
        }
    }
}

/// What an action applies to.
///
/// A whole thread rather than a message: archiving one reply and leaving the
/// rest is not something anyone means, and the list is a list of conversations.
public struct ActionTarget: Hashable, Sendable, Identifiable {
    public var threadID: String
    public var accountKey: String
    public var accountID: AccountID
    public var emailIDs: [EmailID]

    /// Scoped by account: thread ids are unique only within one.
    public var id: String { "\(accountKey)#\(threadID)" }

    public init(threadID: String, accountKey: String, accountID: AccountID, emailIDs: [EmailID]) {
        self.threadID = threadID
        self.accountKey = accountKey
        self.accountID = accountID
        self.emailIDs = emailIDs
    }
}
