import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The queue is the one place in this app holding something that exists
/// nowhere else, so these tests are about survival: does a message written
/// offline come back, byte for byte, after the process that wrote it is gone.
@Suite("Outbox")
struct OutboxTests {
    /// Each test gets its own server id, so the on-disk directories cannot
    /// collide — the queue is deliberately real files, not a fake.
    private func makeOutbox() -> Outbox {
        Outbox(serverID: "test-\(UUID().uuidString)")
    }

    private func message(
        subject: String = "Hello",
        body: String = "Body",
        attachments: [Outbox.Attachment] = []
    ) -> Outbox.PendingMessage {
        Outbox.PendingMessage(
            accountKey: "srv/1",
            accountID: AccountID("1"),
            identityID: IdentityID(rawValue: "3"),
            from: EmailAddress(name: "Me", email: "me@example.com"),
            to: [EmailAddress(name: nil, email: "you@example.com")],
            subject: subject,
            body: body,
            attachments: attachments
        )
    }

    @Test("A queued message survives being reloaded from disk")
    func roundTrip() async throws {
        let outbox = makeOutbox()
        let queued = message(subject: "Written on a train", body: "No signal here.")

        try await outbox.enqueue(queued)

        let reloaded = await outbox.pending()

        #expect(reloaded.count == 1)
        #expect(reloaded.first?.id == queued.id)
        #expect(reloaded.first?.subject == "Written on a train")
        #expect(reloaded.first?.body == "No signal here.")
        #expect(reloaded.first?.to.first?.email == "you@example.com")
        #expect(reloaded.first?.from?.name == "Me")
        #expect(reloaded.first?.identityID.rawValue == "3")
    }

    /// Attachment bytes live beside the metadata rather than inside it. If
    /// they came back short or empty the send would succeed and the
    /// recipient would get an empty PDF, which is worse than a failure.
    @Test("Attachment bytes come back intact")
    func attachmentBytes() async throws {
        let outbox = makeOutbox()
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })

        try await outbox.enqueue(
            message(
                attachments: [
                    Outbox.Attachment(name: "report.pdf", type: "application/pdf", data: bytes)
                ]))

        let attachment = try #require(await outbox.pending().first?.attachments.first)

        #expect(attachment.data == bytes)
        #expect(attachment.name == "report.pdf")
        #expect(attachment.type == "application/pdf")
    }

    /// Two files can genuinely be called the same thing, and the display name
    /// comes from a picker rather than from us. Storing by display name would
    /// mean the second overwrote the first.
    @Test("Two attachments with the same display name are both kept")
    func duplicateAttachmentNames() async throws {
        let outbox = makeOutbox()
        let first = Data("first".utf8)
        let second = Data("second".utf8)

        try await outbox.enqueue(
            message(attachments: [
                Outbox.Attachment(name: "photo.jpg", type: "image/jpeg", data: first),
                Outbox.Attachment(name: "photo.jpg", type: "image/jpeg", data: second),
            ]))

        let stored = try #require(await outbox.pending().first).attachments

        #expect(stored.count == 2)
        #expect(Set(stored.map(\.data)) == [first, second])
    }

    /// Oldest first. A reply queued after the message it answers must not
    /// arrive before it.
    @Test("Pending messages come back oldest first")
    func ordering() async throws {
        let outbox = makeOutbox()

        var first = message(subject: "First")
        first.queuedAt = Date(timeIntervalSince1970: 1_000)
        var second = message(subject: "Second")
        second.queuedAt = Date(timeIntervalSince1970: 2_000)
        var third = message(subject: "Third")
        third.queuedAt = Date(timeIntervalSince1970: 3_000)

        // Enqueued out of order on purpose: directory listings have no
        // guaranteed order, so sorting has to be the queue's job.
        try await outbox.enqueue(second)
        try await outbox.enqueue(third)
        try await outbox.enqueue(first)

        #expect(await outbox.pending().map(\.subject) == ["First", "Second", "Third"])
    }

    @Test("Removing a message empties the queue")
    func remove() async throws {
        let outbox = makeOutbox()
        let queued = try await outbox.enqueue(message())

        await outbox.remove(queued.id)

        #expect(await outbox.count() == 0)
    }

    /// A failure has to be durable too: relaunching should still say why the
    /// message is sitting there, and should not have reset the attempt count.
    @Test("A recorded failure persists and does not duplicate the message")
    func recordFailure() async throws {
        let outbox = makeOutbox()
        let queued = try await outbox.enqueue(message(subject: "Stuck"))

        await outbox.recordFailure(queued.id, reason: "Waiting for the server.")
        await outbox.recordFailure(queued.id, reason: "Waiting for the server.")

        let pending = await outbox.pending()

        #expect(pending.count == 1)
        #expect(pending.first?.attempts == 2)
        #expect(pending.first?.lastFailure == "Waiting for the server.")
        #expect(pending.first?.lastAttemptAt != nil)
    }

    /// Recording a failure must not lose the bytes it was carrying — it
    /// rewrites the same folder the attachments live in.
    @Test("A failure keeps the attachments")
    func failureKeepsAttachments() async throws {
        let outbox = makeOutbox()
        let bytes = Data("payload".utf8)
        let queued = try await outbox.enqueue(
            message(attachments: [
                Outbox.Attachment(name: "a.txt", type: "text/plain", data: bytes)
            ]))

        await outbox.recordFailure(queued.id, reason: "Nope.")

        #expect(await outbox.pending().first?.attachments.first?.data == bytes)
    }

    /// Signing into a different server must not inherit the previous one's
    /// unsent mail — it would be sent from an identity that no longer exists.
    @Test("Queues are scoped to one server")
    func scoping() async throws {
        let first = Outbox(serverID: "nas.local")
        let second = Outbox(serverID: "other.example")

        _ = try await first.enqueue(message(subject: "For the NAS"))

        #expect(await second.count() == 0)

        // Cleanup, since these two use fixed ids rather than a fresh one.
        for queued in await first.pending() { await first.remove(queued.id) }
    }

    /// Hostnames contain dots and can contain characters a path segment
    /// should not. A colon or a slash reaching the filesystem is either a
    /// write failure or a write somewhere unintended.
    @Test(
        "Server ids are reduced to safe directory names",
        arguments: [
            ("nas.local", "nas.local"),
            ("mail.example.com:8443", "mail.example.com-8443"),
            ("../escape", "..-escape"),
            ("a/b", "a-b"),
        ])
    func slugging(serverID: String, expected: String) {
        #expect(Outbox.slug(serverID) == expected)
    }
}
