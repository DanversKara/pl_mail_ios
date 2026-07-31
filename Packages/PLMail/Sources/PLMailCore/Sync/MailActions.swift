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

    /// Puts a conversation away until a time, or brings it back now.
    ///
    /// Not an Email/set: snooze is thread state, and the server does the label
    /// moves — out of the Inbox now, back into it when the time comes, marked
    /// unread so it is noticed. So this cannot go through `apply`, which is
    /// built around one EmailSet and its inverse.
    ///
    /// The local change is the same one archiving makes — the row leaves the
    /// list — because that is what happens on the server too.
    public func snooze(_ target: ActionTarget, until: Date?) async {
        failure = nil

        let removed: [RemovedFeedRow]

        if until == nil {
            // Waking puts it back in the Inbox, which this list may or may not
            // be; a refetch settles it rather than a guessed local insert.
            removed = []
        } else {
            removed =
                (try? await store.removeFromFeeds(
                    target.threadID, accountKey: target.accountKey)) ?? []
        }

        let threadID = ThreadID(target.threadID)

        offerUndo(until == nil ? "Woken" : "Snoozed \(Self.describe(until))") { [weak self] in
            guard let self else { return }

            _ = await sendThreadSet(
                .snooze(threadID, until: nil, accountID: target.accountID), target: target)
            await refetch(target)
        }

        let sent = await sendThreadSet(
            .snooze(
                threadID, until: until.map(UTCDate.init), accountID: target.accountID),
            target: target)

        guard sent else {
            dismissUndo()
            try? await store.restoreFeedRows(removed)
            await refetch(target)

            return
        }

        // The server changed which labels the messages carry, so the cached
        // copies are stale in a way only it can settle.
        await refetch(target)
    }

    /// - Returns: Whether the server accepted the change.
    private func sendThreadSet(_ request: ThreadSet, target: ActionTarget) async -> Bool {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(request)
            let results = try await client.send(builder)

            if let error = results.failure(of: call) { throw error }

            let result = try results.result(of: call)

            if let refused = result.notUpdated, refused.isEmpty == false {
                failure = "The server wouldn't change that snooze."
                logger.error("Snooze refused: \(String(describing: refused), privacy: .public)")

                return false
            }

            return true
        } catch {
            failure = "Couldn't reach the server. Nothing was changed."
            logger.error("Snooze failed: \(error, privacy: .public)")

            return false
        }
    }

    private static func describe(_ until: Date?) -> String {
        guard let until else { return "" }

        return "until " + until.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    // MARK: - Bulk

    /// What a selection can be acted on with.
    ///
    /// A label is named by its **user-scoped** ``LabelID`` rather than a
    /// mailbox id, because a selection can span accounts and a mailbox id
    /// belongs to exactly one of them. The binding is resolved per account on
    /// the way out — which is the whole reason the server exposes `labelId`.
    public enum BulkAction: Sendable {
        case archive
        case trash
        case setSeen(Bool)
        case setFlagged(Bool)
        case setLabel(Bool, LabelID, name: String)
    }

    /// Applies one action to many conversations at once.
    ///
    /// Every account's changes go out in a **single** batch — one `Email/set`
    /// per account, all in one POST — rather than a request per conversation.
    /// Selecting forty messages and archiving them is one round trip, which
    /// over a home uplink is the difference between instant and a progress
    /// spinner.
    ///
    /// One undo covers the whole selection, because that is what was done: an
    /// undo bar per conversation would be forty toasts for one gesture.
    public func perform(_ action: BulkAction, on targets: [ActionTarget]) async {
        guard targets.isEmpty == false else { return }

        failure = nil

        let byAccount = Dictionary(grouping: targets, by: \.accountKey)
        var requests: [(target: ActionTarget, request: EmailSet, undo: EmailSet)] = []

        for (accountKey, group) in byAccount {
            guard let pair = await self.requests(for: action, accountKey: accountKey, group: group)
            else { continue }

            // One target per account stands in for the group when a refetch is
            // needed; it carries every email id in that account's selection.
            let combined = ActionTarget(
                threadID: group[0].threadID,
                accountKey: accountKey,
                accountID: group[0].accountID,
                emailIDs: group.flatMap(\.emailIDs)
            )

            requests.append((combined, pair.request, pair.undo))
        }

        guard requests.isEmpty == false else { return }

        var removedRows: [RemovedFeedRow] = []

        for target in targets {
            removedRows += (try? await localChange(for: action, target: target)) ?? []
        }

        let undoRequests = requests.map { (target: $0.target, request: $0.undo) }
        let restored = removedRows

        offerUndo(Self.describe(action, count: targets.count)) { [weak self] in
            guard let self else { return }

            for pair in undoRequests {
                _ = await send(pair.request, target: pair.target)
                await refetch(pair.target)
            }
        }

        // Sent as one batch, then inspected per call: one account being
        // read-only must not silently discard the others' changes.
        var accepted = true

        for pair in requests where await send(pair.request, target: pair.target) == false {
            accepted = false
        }

        guard accepted else {
            dismissUndo()
            try? await store.restoreFeedRows(restored)

            for pair in requests {
                await refetch(pair.target)
            }

            return
        }
    }

    /// The wire pair for one account's share of a bulk action.
    private func requests(
        for action: BulkAction, accountKey: String, group: [ActionTarget]
    ) async -> (request: EmailSet, undo: EmailSet)? {
        let ids = group.flatMap(\.emailIDs)
        let accountID = group[0].accountID

        switch action {
        case .archive:
            guard let inbox = try? await store.mailbox(role: .inbox, accountKey: accountKey)
            else { return nil }

            let archive = try? await store.mailbox(role: .archive, accountKey: accountKey)

            return (
                EmailSet.archive(ids: ids, inbox: inbox, archive: archive, accountID: accountID),
                EmailSet.moveToInbox(
                    ids: ids, inbox: inbox, leaving: archive, accountID: accountID)
            )

        case .trash:
            guard let inbox = try? await store.mailbox(role: .inbox, accountKey: accountKey)
            else { return nil }

            return (
                EmailSet.trash(ids: ids, accountID: accountID),
                EmailSet.moveToInbox(ids: ids, inbox: inbox, accountID: accountID)
            )

        case .setSeen(let isSeen):
            return (
                EmailSet.setSeen(isSeen, ids: ids, accountID: accountID),
                EmailSet.setSeen(isSeen == false, ids: ids, accountID: accountID)
            )

        case .setFlagged(let isFlagged):
            return (
                EmailSet.setFlagged(isFlagged, ids: ids, accountID: accountID),
                EmailSet.setFlagged(isFlagged == false, ids: ids, accountID: accountID)
            )

        case .setLabel(let isApplied, let labelID, _):
            // An account with no binding for this label is skipped rather than
            // failed: labels are user-scoped and a selection spanning accounts
            // will routinely include one that has never seen this label.
            guard
                let mailbox = try? await store.mailbox(labelID: labelID, accountKey: accountKey)
            else { return nil }

            return (
                EmailSet.setLabel(isApplied, mailbox: mailbox, ids: ids, accountID: accountID),
                EmailSet.setLabel(
                    isApplied == false, mailbox: mailbox, ids: ids, accountID: accountID)
            )
        }
    }

    private func localChange(
        for action: BulkAction, target: ActionTarget
    ) async throws
        -> [RemovedFeedRow]
    {
        let emailIDs = target.emailIDs.map(\.rawValue)

        switch action {
        case .archive, .trash:
            return try await store.removeFromFeeds(target.threadID, accountKey: target.accountKey)

        case .setSeen(let isSeen):
            try await store.setSeen(isSeen, emailIDs: emailIDs, accountKey: target.accountKey)

        case .setFlagged(let isFlagged):
            try await store.setFlagged(
                isFlagged, emailIDs: emailIDs, accountKey: target.accountKey)

        case .setLabel(let isApplied, let labelID, _):
            guard
                let mailbox = try? await store.mailbox(
                    labelID: labelID, accountKey: target.accountKey)
            else { return [] }

            try await store.setMailbox(
                isApplied, mailboxID: mailbox.rawValue, emailIDs: emailIDs,
                accountKey: target.accountKey)
        }

        return []
    }

    private static func describe(_ action: BulkAction, count: Int) -> String {
        let noun = count == 1 ? "conversation" : "conversations"

        return switch action {
        case .archive: "Archived \(count) \(noun)"
        case .trash: "Moved \(count) \(noun) to Trash"
        case .setSeen(let isSeen): "Marked \(count) \(noun) \(isSeen ? "read" : "unread")"
        case .setFlagged(let isFlagged): "\(isFlagged ? "Starred" : "Unstarred") \(count) \(noun)"
        case .setLabel(let isApplied, _, let name):
            isApplied
                ? "Labelled \(count) \(noun) \(name)" : "Removed \(name) from \(count) \(noun)"
        }
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
