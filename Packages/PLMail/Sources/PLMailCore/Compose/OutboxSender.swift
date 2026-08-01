import Foundation
import JMAPKit
import OSLog
import Observation

/// Gets queued mail out once the server can be reached.
///
/// Kept separate from the composer because the composer is gone by the time
/// most of this matters: someone writes a message on a train, dismisses the
/// sheet, and the send has to happen later without any UI being on screen.
@MainActor
@Observable
public final class OutboxSender {
    /// How many messages are waiting. Drives the sidebar row, so it is the one
    /// piece of state a view observes.
    public private(set) var pendingCount = 0
    public private(set) var isSending = false

    /// The earliest time something in the queue becomes due, or nil when
    /// nothing is being held back. Read by the app when it goes to the
    /// background, to ask the system for a wake-up nearer that time.
    public private(set) var nextDueAt: Date?

    /// Exposed so the composer files into the same queue this drains. Two
    /// `Outbox` values over one directory would work — it is all on disk — but
    /// sharing one keeps the count and the queue from disagreeing.
    public let queue: Outbox
    private let client: JMAPClient
    private let store: SyncStore
    private let logger = Logger(subsystem: "de.plmail", category: "outbox")
    private var drainTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?

    public init(outbox: Outbox, client: JMAPClient, store: SyncStore) {
        queue = outbox
        self.client = client
        self.store = store
    }

    public func refreshCount() async {
        let queued = await queue.pending()

        pendingCount = queued.count
        armWake(among: queued)
    }

    public func pending() async -> [Outbox.PendingMessage] {
        await queue.pending()
    }

    /// Drops a queued message. The only way out for one the server will never
    /// accept — a recipient that does not exist, an account since removed —
    /// and how a scheduled message is called back before it goes.
    public func discard(_ id: UUID) async {
        await queue.remove(id)
        await refreshCount()
    }

    /// Releases a message that was being held back, and sends it.
    public func sendNow(_ id: UUID) async {
        await queue.reschedule(id, to: nil)
        await refreshCount()
        drain()
    }

    /// Moves a scheduled message to a different time.
    public func reschedule(_ id: UUID, to date: Date) async {
        await queue.reschedule(id, to: date)
        await refreshCount()
    }

    /// Tries to send everything waiting.
    ///
    /// Single-flighted: this is called from app foreground, from the sync
    /// service when a refresh succeeds, and from the composer right after
    /// queuing. Two drains at once would send the same message twice.
    public func drain() {
        guard drainTask == nil else { return }

        drainTask = Task { [weak self] in
            defer { self?.drainTask = nil }

            await self?.drainNow()
        }
    }

    /// Waits for a drain that is already running.
    ///
    /// Almost nothing waits on a drain — the composer closes the moment the
    /// message is on disk, which is the point. The exception is the background
    /// refresh, which must not report itself finished while a send is still in
    /// flight: the system is entitled to suspend the process the instant it
    /// does, and the send would be cut off mid-request.
    public func settle() async {
        await drainTask?.value
    }

    private func drainNow() async {
        let queued = await queue.pending()

        pendingCount = queued.count
        armWake(among: queued)

        // Everything held back for later is left exactly where it is. A drain
        // happens on foreground, on the network returning and on launch —
        // moments that say nothing about whether a scheduled message is ready.
        let now = Date.now
        let due = queued.filter { $0.isDue(at: now) }

        guard due.isEmpty == false else { return }

        isSending = true
        defer { isSending = false }

        for message in due {
            do {
                try await send(message)
                await queue.remove(message.id)
            } catch {
                // Stop at the first failure rather than working through the
                // rest. They share one server: if this one could not go out,
                // neither can the next, and hammering an unreachable NAS with
                // the whole queue is exactly what the circuit breaker exists to
                // prevent.
                await queue.recordFailure(message.id, reason: Self.describe(error))
                logger.error("Outbox send failed: \(error, privacy: .public)")

                break
            }
        }

        await refreshCount()
    }

    /// Arranges to drain again when the next scheduled message falls due.
    ///
    /// **A timer, not a promise.** It only runs while the process does, which
    /// is why nothing depends on it: a message becomes due on the wall clock,
    /// and the drains on foreground, on the network returning, on launch and on
    /// the background refresh are what actually get it out. This is the case
    /// where the app happens to be open at the moment — worth having, because
    /// otherwise a message scheduled for ten minutes' time sits there while
    /// somebody watches it.
    private func armWake(among queued: [Outbox.PendingMessage]) {
        let now = Date.now
        let next = queued.compactMap(\.sendAfter).filter { $0 > now }.min()

        wakeTask?.cancel()
        nextDueAt = next

        guard let next else { return }

        wakeTask = Task { [weak self] in
            // A second past the due time rather than exactly on it: waking a
            // hair early would find nothing due, re-arm, and spin.
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 1))

            guard Task.isCancelled == false else { return }

            self?.drain()
        }
    }

    /// The one send path.
    ///
    /// The composer queues and then asks for a drain rather than sending
    /// directly, so there is exactly one implementation of "turn this into a
    /// draft and submit it" — two would drift, and the one that drifted would
    /// be the one nobody watches.
    private func send(_ message: Outbox.PendingMessage) async throws {
        var uploaded: [EmailCreate.Draft.Attachment] = []

        for attachment in message.attachments {
            let blob = try await client.upload(
                attachment.data, type: attachment.type, accountID: message.accountID)

            uploaded.append(
                EmailCreate.Draft.Attachment(
                    blobID: blob.blobID, type: attachment.type, name: attachment.name))
        }

        guard
            let drafts = try await store.mailbox(role: .drafts, accountKey: message.accountKey)
        else {
            throw SendFailure.noDraftsMailbox
        }

        let draft = EmailCreate.Draft(
            drafts: drafts,
            from: message.from,
            to: message.to,
            cc: message.cc,
            bcc: message.bcc,
            subject: message.subject,
            text: message.body,
            html: message.html,
            inReplyTo: message.inReplyTo,
            references: message.references,
            attachments: uploaded
        )

        var builder = RequestBuilder(session: try await client.session())

        // Continuing an existing draft rewrites it; a new message creates one
        // and refers to it by creation id in the same round trip.
        if let editingEmailID = message.editingEmailID {
            let update = builder.add(
                EmailUpdateDraft(
                    accountID: message.accountID,
                    emailID: EmailID(editingEmailID),
                    draft: draft))
            let submit = builder.add(
                EmailSubmissionSet(
                    accountID: message.accountID,
                    emailID: editingEmailID,
                    identityID: message.identityID))

            let results = try await client.send(builder)

            if let error = results.failure(of: update) { throw error }
            if let refused = try results.result(of: update).notUpdated, refused.isEmpty == false {
                throw SendFailure.refused
            }
            if let error = results.failure(of: submit) { throw error }
            if let refused = try results.result(of: submit).notCreated, refused.isEmpty == false {
                throw SendFailure.refused
            }

            return
        }

        let create = builder.add(EmailCreate(accountID: message.accountID, draft: draft))
        let submit = builder.add(
            EmailSubmissionSet(
                accountID: message.accountID,
                emailID: "#\(EmailCreate.creationID)",
                identityID: message.identityID))

        let results = try await client.send(builder)

        if let error = results.failure(of: create) { throw error }
        if let refused = try results.result(of: create).notCreated, refused.isEmpty == false {
            throw SendFailure.refused
        }
        if let error = results.failure(of: submit) { throw error }
        if let refused = try results.result(of: submit).notCreated, refused.isEmpty == false {
            throw SendFailure.refused
        }
    }

    enum SendFailure: Error {
        case noDraftsMailbox
        case refused
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case SendFailure.noDraftsMailbox:
            "This account has no Drafts mailbox to send from."
        case SendFailure.refused:
            "The server wouldn't accept this message."
        case JMAPError.notAuthenticated:
            "Sign in again to send this."
        default:
            "Waiting for the server."
        }
    }
}
