import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// Draining a queue that has something scheduled in it.
///
/// The store here is empty on purpose, so every message the sender actually
/// picks up fails at "this account has no Drafts mailbox" without a request
/// leaving. That failure is the signal: a message that was *tried* carries an
/// attempt and a reason, a message that was skipped carries neither, and the
/// two are what these tests tell apart.
@Suite("Outbox sender")
@MainActor
struct OutboxSenderTests {
    private func makeSender(_ outbox: Outbox) -> OutboxSender {
        OutboxSender(
            outbox: outbox,
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")!,
                credential: .appPassword("plmail_test"),
                transport: MockTransport(body: Data("{}".utf8), statusCode: 500)
            ),
            store: SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
        )
    }

    private func makeOutbox() -> Outbox {
        Outbox(serverID: "test-\(UUID().uuidString)")
    }

    private func message(subject: String) -> Outbox.PendingMessage {
        Outbox.PendingMessage(
            accountKey: "srv/1",
            accountID: AccountID("1"),
            identityID: IdentityID(rawValue: "3"),
            from: EmailAddress(name: "Me", email: "me@example.com"),
            to: [EmailAddress(name: nil, email: "you@example.com")],
            subject: subject,
            body: "Body"
        )
    }

    private func drainAndSettle(_ sender: OutboxSender) async {
        sender.drain()
        await sender.settle()
    }

    /// The whole feature in one assertion: a drain is not evidence that a
    /// scheduled message is ready.
    ///
    /// The held message is queued *first* deliberately. The drain works oldest
    /// first and stops at the first failure, so a sender that ignored the
    /// schedule would try this one and never reach the other — which is
    /// exactly the pair of counts asserted below.
    @Test("A message scheduled for later is left alone by a drain")
    func skipsWhatIsNotDue() async throws {
        let outbox = makeOutbox()

        var held = message(subject: "Tomorrow")
        held.queuedAt = Date(timeIntervalSince1970: 1_000)
        held.sendAfter = .now.addingTimeInterval(3_600)

        var now = message(subject: "Now")
        now.queuedAt = Date(timeIntervalSince1970: 2_000)

        try await outbox.enqueue(held)
        try await outbox.enqueue(now)

        await drainAndSettle(makeSender(outbox))

        let stored = await outbox.pending()
        let reloadedHeld = try #require(stored.first { $0.subject == "Tomorrow" })
        let reloadedNow = try #require(stored.first { $0.subject == "Now" })

        #expect(reloadedHeld.attempts == 0)
        #expect(reloadedHeld.lastFailure == nil)
        #expect(reloadedNow.attempts == 1)
        #expect(reloadedNow.lastFailure != nil)
    }

    /// A queue holding nothing but scheduled mail must not look like one that
    /// is trying and failing — no spinner, no attempt, no request.
    @Test("A queue of nothing but scheduled mail does not start sending")
    func nothingDue() async throws {
        let outbox = makeOutbox()

        var held = message(subject: "Later")
        held.sendAfter = .now.addingTimeInterval(3_600)

        try await outbox.enqueue(held)

        let sender = makeSender(outbox)

        await drainAndSettle(sender)

        #expect(sender.isSending == false)
        #expect(sender.pendingCount == 1, "it is still waiting, and the sidebar should say so")
        #expect(await outbox.pending().first?.attempts == 0)
    }

    /// What the app asks the system to wake it for. The earliest one, because
    /// a wake-up for the second would be too late for the first.
    @Test("The next due time is the earliest one still ahead")
    func nextDue() async throws {
        let outbox = makeOutbox()
        let soon = Date.now.addingTimeInterval(600)
        let later = Date.now.addingTimeInterval(6_000)

        var first = message(subject: "Later")
        first.sendAfter = later
        var second = message(subject: "Soon")
        second.sendAfter = soon
        var due = message(subject: "Now")
        due.sendAfter = .now.addingTimeInterval(-60)

        try await outbox.enqueue(first)
        try await outbox.enqueue(second)
        try await outbox.enqueue(due)

        let sender = makeSender(outbox)

        await sender.refreshCount()

        #expect(sender.nextDueAt == soon)
    }

    @Test("Nothing scheduled means nothing to wake for")
    func noNextDue() async throws {
        let outbox = makeOutbox()

        try await outbox.enqueue(message(subject: "Now"))

        let sender = makeSender(outbox)

        await sender.refreshCount()

        #expect(sender.nextDueAt == nil)
    }

    /// "Send now" is the way back out of a schedule, and it has to clear the
    /// time on disk — not just send once — or the message would be held again
    /// after a relaunch.
    @Test("Sending a held message now clears its schedule")
    func sendNow() async throws {
        let outbox = makeOutbox()

        var held = message(subject: "Held")
        held.sendAfter = .now.addingTimeInterval(3_600)

        try await outbox.enqueue(held)

        let sender = makeSender(outbox)

        await sender.sendNow(held.id)
        await sender.settle()

        // The send itself fails — there is no Drafts mailbox in this store —
        // which is what leaves the message here to be inspected.
        let stored = try #require(await outbox.pending().first)

        #expect(stored.sendAfter == nil)
        #expect(sender.nextDueAt == nil)
    }
}
