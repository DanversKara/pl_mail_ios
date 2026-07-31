import Foundation
import JMAPKit
import OSLog

/// Messages written but not yet accepted by the server.
///
/// **Deliberately not in the SwiftData store.** That store's governing rule is
/// that everything in it is reconstructible from the server, which is what
/// licenses deleting and rebuilding it on any migration or corruption failure.
/// An unsent message is the one thing in this app that exists nowhere else —
/// putting it there would mean a schema change could silently throw away
/// somebody's mail.
///
/// So it lives in Application Support: backed up, and never reclaimed by the
/// system the way `Caches` may be.
///
/// One directory per message rather than one big file. Attachments are bytes,
/// sometimes tens of megabytes of them, and base64 inside a single JSON
/// document would mean rewriting every queued message to append one.
public actor Outbox {
    private let directory: URL
    private let logger = Logger(subsystem: "de.plmail", category: "outbox")

    /// - Parameter serverID: Scopes the queue to one server, so signing into a
    ///   different one cannot inherit mail addressed from the previous
    ///   account.
    public init(serverID: String) {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory

        directory =
            base
            .appending(path: "plmail-outbox", directoryHint: .isDirectory)
            .appending(path: Self.slug(serverID), directoryHint: .isDirectory)

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Everything waiting, oldest first — the order it will be sent in.
    public func pending() -> [PendingMessage] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }

        return
            entries
            .filter { $0.hasDirectoryPath }
            .compactMap(load(from:))
            .sorted { $0.queuedAt < $1.queuedAt }
    }

    public func count() -> Int {
        pending().count
    }

    /// Files a message for later.
    @discardableResult
    public func enqueue(_ message: PendingMessage) throws -> PendingMessage {
        let folder = directory.appending(path: message.id.uuidString, directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Attachments first: a metadata file that referenced bytes which had
        // not landed yet would be a queued message that could never be sent.
        for attachment in message.attachments {
            try attachment.data.write(
                to: folder.appending(path: attachment.fileName), options: .atomic)
        }

        let record = Record(message)
        try JSONEncoder().encode(record).write(
            to: folder.appending(path: "message.json"), options: .atomic)

        return message
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(
            at: directory.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    /// Records that an attempt failed, so the UI can say so and a message that
    /// will never send can be told apart from one that has not been tried.
    public func recordFailure(_ id: UUID, reason: String) {
        guard var message = pending().first(where: { $0.id == id }) else { return }

        message.attempts += 1
        message.lastFailure = reason
        message.lastAttemptAt = .now

        try? enqueue(message)
    }

    // MARK: - Storage

    private func load(from folder: URL) -> PendingMessage? {
        guard let data = try? Data(contentsOf: folder.appending(path: "message.json")),
            let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }

        let attachments = record.attachments.compactMap { attachment -> Attachment? in
            guard let bytes = try? Data(contentsOf: folder.appending(path: attachment.fileName))
            else { return nil }

            return Attachment(
                fileName: attachment.fileName, name: attachment.name, type: attachment.type,
                data: bytes)
        }

        return record.message(attachments: attachments)
    }

    /// Directory names come from a server id, which is a hostname and may
    /// contain characters a path should not. Internal rather than private
    /// because a slug that lets `../` through writes outside the queue.
    static func slug(_ serverID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_."))

        return String(
            serverID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    /// The on-disk shape. Separate from ``PendingMessage`` so the bytes are not
    /// part of what gets encoded.
    private struct Record: Codable {
        var id: UUID
        var accountKey: String
        var accountID: String
        var identityID: String
        var from: EmailAddress?
        var to: [EmailAddress]
        var cc: [EmailAddress]
        var bcc: [EmailAddress]
        var subject: String
        var body: String
        /// Optional so a queue written before formatting existed still
        /// decodes. Those messages send as plain text, which is what they
        /// were.
        var html: String?
        var inReplyTo: [String]?
        var references: [String]?
        var editingEmailID: String?
        var queuedAt: Date
        var attempts: Int
        var lastFailure: String?
        var lastAttemptAt: Date?
        var attachments: [AttachmentRecord]

        struct AttachmentRecord: Codable {
            var fileName: String
            var name: String
            var type: String
        }

        init(_ message: PendingMessage) {
            id = message.id
            accountKey = message.accountKey
            accountID = message.accountID.rawValue
            identityID = message.identityID.rawValue
            from = message.from
            to = message.to
            cc = message.cc
            bcc = message.bcc
            subject = message.subject
            body = message.body
            html = message.html
            inReplyTo = message.inReplyTo
            references = message.references
            editingEmailID = message.editingEmailID
            queuedAt = message.queuedAt
            attempts = message.attempts
            lastFailure = message.lastFailure
            lastAttemptAt = message.lastAttemptAt
            attachments = message.attachments.map {
                AttachmentRecord(fileName: $0.fileName, name: $0.name, type: $0.type)
            }
        }

        func message(attachments: [Attachment]) -> PendingMessage {
            var message = PendingMessage(
                id: id,
                accountKey: accountKey,
                accountID: AccountID(accountID),
                identityID: IdentityID(rawValue: identityID),
                from: from,
                to: to,
                cc: cc,
                bcc: bcc,
                subject: subject,
                body: body,
                html: html,
                inReplyTo: inReplyTo,
                references: references,
                editingEmailID: editingEmailID,
                attachments: attachments
            )
            message.queuedAt = queuedAt
            message.attempts = attempts
            message.lastFailure = lastFailure
            message.lastAttemptAt = lastAttemptAt

            return message
        }
    }
}

extension Outbox {
    /// One file waiting to go out with a queued message.
    public struct Attachment: Hashable, Sendable {
        /// Unique within the message's folder. Not the display name: two files
        /// called `photo.jpg` are ordinary, and a name from a sender is not
        /// something to build a path from.
        public var fileName: String
        public var name: String
        public var type: String
        public var data: Data

        public init(fileName: String = UUID().uuidString, name: String, type: String, data: Data) {
            self.fileName = fileName
            self.name = name
            self.type = type
            self.data = data
        }
    }

    /// A message written but not yet accepted by the server.
    public struct PendingMessage: Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var accountKey: String
        public var accountID: AccountID
        public var identityID: IdentityID
        public var from: EmailAddress?
        public var to: [EmailAddress]
        public var cc: [EmailAddress] = []
        public var bcc: [EmailAddress] = []
        public var subject: String
        /// The plain-text alternative.
        public var body: String
        /// The formatted body, already serialised. Serialised at queue time
        /// rather than at send time so the bytes on disk are exactly what will
        /// go out — a message that renders differently after a relaunch would
        /// be impossible to reason about.
        public var html: String?
        public var inReplyTo: [String]?
        public var references: [String]?
        /// Set when this began as an existing draft, so sending rewrites that
        /// message rather than leaving a stale copy behind.
        public var editingEmailID: String?
        public var attachments: [Attachment] = []

        public var queuedAt = Date.now
        public var attempts = 0
        public var lastFailure: String?
        public var lastAttemptAt: Date?

        public var displayRecipient: String {
            to.first.map { $0.name ?? $0.email } ?? ""
        }
    }
}
