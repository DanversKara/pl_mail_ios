import Foundation
import JMAPKit
import OSLog
import Observation

/// Writing and sending a message.
///
/// One draft is created and submitted in a **single round trip**: the draft
/// gets a creation id, and the submission refers to it as `#draft`. Over a
/// home uplink that is the difference between sending feeling instant and
/// feeling like two requests.
@MainActor
@Observable
public final class ComposeModel {
    public enum Kind: Sendable {
        case new
        case reply(to: MessageSnapshot, all: Bool)
        case forward(MessageSnapshot)
    }

    public enum Status: Equatable, Sendable {
        case editing
        /// Held back so it can still be recalled. The server does not apply
        /// the web UI's grace period to JMAP submissions — a JMAP client asked
        /// to send now — so the window is this client's own.
        case sending(remaining: Int)
        case sent
        case failed(String)
    }

    public var to: String = ""
    public var cc: String = ""
    public var bcc: String = ""
    public var subject: String = ""
    public var body: String = ""
    public var selectedIdentity: IdentitySnapshot?
    public private(set) var identities: [IdentitySnapshot] = []
    public private(set) var status: Status = .editing

    /// Files picked for this message, not yet uploaded.
    ///
    /// Held as bytes rather than as security-scoped URLs: a picked file's URL
    /// stops resolving once the picker's scope is released, and a draft that
    /// sends an hour later would find nothing there.
    public private(set) var attachments: [PendingAttachment] = []

    /// Everyone this account has corresponded with, for autocomplete.
    ///
    /// Harvested from synced mail rather than fetched: the server exposes no
    /// JMAP Contacts, and the addresses someone actually writes to are all in
    /// the mail already on the device.
    public private(set) var suggestions: [EmailAddress] = []

    /// A file waiting to be sent.
    public struct PendingAttachment: Identifiable, Sendable, Hashable {
        public let id = UUID()
        public var name: String
        public var type: String
        public var data: Data

        public var size: Int { data.count }
    }

    private let kind: Kind
    private let accountKey: String
    private let accountID: AccountID
    private let client: JMAPClient
    private let store: SyncStore
    private let logger = Logger(subsystem: "de.plmail", category: "compose")
    private var sendTask: Task<Void, Never>?

    /// Long enough to catch the "wait, wrong person" moment, short enough that
    /// nobody wonders whether it went.
    private let undoWindow = 5

    public init(
        kind: Kind,
        accountKey: String,
        accountID: AccountID,
        client: JMAPClient,
        store: SyncStore
    ) {
        self.kind = kind
        self.accountKey = accountKey
        self.accountID = accountID
        self.client = client
        self.store = store

        prefill()
    }

    public var canSend: Bool {
        recipients(from: to).isEmpty == false && status == .editing
    }

    public func attach(name: String, type: String, data: Data) {
        attachments.append(PendingAttachment(name: name, type: type, data: data))
    }

    public func removeAttachment(_ id: PendingAttachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    public var attachmentsSize: Int {
        attachments.reduce(0) { $0 + $1.size }
    }

    public var isSending: Bool {
        if case .sending = status { return true }
        return false
    }

    // MARK: - Setup

    public func load() async {
        identities = (try? await store.identities(accountKey: accountKey)) ?? []
        selectedIdentity = selectedIdentity ?? identities.first
        suggestions = (try? await store.knownAddresses(accountKey: accountKey)) ?? []

        // Fetching is cheap and the list is small, but a stale identity list
        // means sending from an alias that no longer exists.
        await refreshIdentities()
    }

    private func refreshIdentities() async {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let get = builder.add(IdentityGet(accountID: accountID))
            let results = try await client.send(builder)

            try await store.replaceIdentities(
                try results.result(of: get).list, accountKey: accountKey)

            identities = (try? await store.identities(accountKey: accountKey)) ?? identities
            selectedIdentity =
                identities.first { $0.id == selectedIdentity?.id } ?? identities.first
        } catch {
            logger.error("Could not refresh identities: \(error, privacy: .public)")
        }
    }

    /// Fills in what a reply or forward already knows.
    private func prefill() {
        switch kind {
        case .new:
            break

        case .reply(let message, let all):
            to = message.fromAddress ?? ""

            if all {
                // Everyone except the sender, who is already in `to`, and
                // without duplicates — replying-all to a thread you are on
                // should not put you in your own recipients.
                let others = (message.to + message.cc)
                    .map(\.email)
                    .filter { $0.caseInsensitiveCompare(message.fromAddress ?? "") != .orderedSame }

                cc = Array(Set(others)).sorted().joined(separator: ", ")
            }

            subject = Self.replySubject(message.subject)
            body = "\n\n" + Self.quote(message)

        case .forward(let message):
            subject = Self.forwardSubject(message.subject)
            body = "\n\n" + Self.quote(message)
        }
    }

    static func replySubject(_ subject: String?) -> String {
        let subject = subject ?? ""

        // Not stacked: "Re: Re: Re:" is nobody's idea of a subject line.
        guard subject.lowercased().hasPrefix("re:") == false else { return subject }

        return "Re: \(subject)"
    }

    static func forwardSubject(_ subject: String?) -> String {
        let subject = subject ?? ""

        guard subject.lowercased().hasPrefix("fwd:") == false else { return subject }

        return "Fwd: \(subject)"
    }

    /// The quoted original, in the convention every mail client understands.
    static func quote(_ message: MessageSnapshot) -> String {
        let when = message.receivedAt?.formatted(date: .long, time: .shortened) ?? ""
        let header = "On \(when), \(message.displayName) wrote:"
        let text = message.textBody ?? message.preview

        let quoted =
            text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")

        return "\(header)\n\(quoted)"
    }

    // MARK: - Sending

    /// Queues the message, held back for a few seconds so it can be recalled.
    public func send() {
        guard canSend, let identity = selectedIdentity else { return }

        sendTask = Task {
            for remaining in stride(from: undoWindow, through: 1, by: -1) {
                status = .sending(remaining: remaining)

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    // Cancelled: the user pressed undo.
                    status = .editing
                    return
                }
            }

            await deliver(identity: identity)
        }
    }

    /// Recalls a message still inside its window.
    public func undoSend() {
        sendTask?.cancel()
        sendTask = nil
        status = .editing
    }

    private func deliver(identity: IdentitySnapshot) async {
        guard let drafts = try? await store.mailbox(role: .drafts, accountKey: accountKey) else {
            status = .failed("This account has no Drafts mailbox to send from.")
            return
        }

        // Uploaded here rather than when the file was picked. plMail reclaims
        // unreferenced uploads on a timer, so a draft left open would otherwise
        // send with blob ids the server had already collected.
        let uploaded: [EmailCreate.Draft.Attachment]

        do {
            uploaded = try await upload(attachments)
        } catch {
            status = .failed(Self.describeUploadFailure(error))
            logger.error("Attachment upload failed: \(error, privacy: .public)")
            return
        }

        let draft = EmailCreate.Draft(
            drafts: drafts,
            from: identity.address,
            to: recipients(from: to),
            cc: recipients(from: cc),
            bcc: recipients(from: bcc),
            subject: subject,
            text: body,
            inReplyTo: replyTargets?.inReplyTo,
            references: replyTargets?.references,
            attachments: uploaded
        )

        do {
            var builder = RequestBuilder(session: try await client.session())

            let create = builder.add(EmailCreate(accountID: accountID, draft: draft))
            // The creation id from the call above: one round trip writes the
            // draft and queues it.
            let submit = builder.add(
                EmailSubmissionSet(
                    accountID: accountID,
                    emailID: "#\(EmailCreate.creationID)",
                    identityID: identity.id
                )
            )

            let results = try await client.send(builder)

            if let error = results.failure(of: create) { throw error }

            let created = try results.result(of: create)

            if let refused = created.notCreated, refused.isEmpty == false {
                status = .failed("The server wouldn't accept this message.")
                return
            }

            if let error = results.failure(of: submit) { throw error }

            let submission = try results.result(of: submit)

            if let refused = submission.notCreated, refused.isEmpty == false {
                status = .failed(Self.describe(refused))
                return
            }

            status = .sent
        } catch {
            status = .failed("Couldn't send. The message is saved as a draft.")
            logger.error("Send failed: \(error, privacy: .public)")
        }
    }

    /// Uploads every attachment and returns what to name them by.
    ///
    /// Sequential rather than concurrent: the server advertises a small upload
    /// allowance and these are someone's home server's workers. Three
    /// photographs are not worth saturating it.
    private func upload(
        _ pending: [PendingAttachment]
    ) async throws -> [EmailCreate.Draft.Attachment] {
        var uploaded: [EmailCreate.Draft.Attachment] = []

        for attachment in pending {
            let blob = try await client.upload(
                attachment.data, type: attachment.type, accountID: accountID)

            uploaded.append(
                EmailCreate.Draft.Attachment(
                    blobID: blob.blobID, type: attachment.type, name: attachment.name))
        }

        return uploaded
    }

    private static func describeUploadFailure(_ error: any Error) -> String {
        guard case JMAPError.requestFailed(let type, _) = error else {
            return "Couldn't upload the attachments. The message wasn't sent."
        }

        return type == "tooLarge"
            ? "One of these files is too large for this server."
            : "The server wouldn't accept one of these files."
    }

    private static func describe(_ refusals: [String: JSONValue]) -> String {
        let type = refusals.values.compactMap { $0.objectValue?["type"]?.stringValue }.first

        return switch type {
        case "noRecipients": "This message has no recipients."
        case "forbidden": "This account isn't allowed to send."
        default: "The server wouldn't send this message."
        }
    }

    /// Threading headers, so a reply continues its conversation.
    private var replyTargets: (inReplyTo: [String], references: [String])? {
        guard case .reply(let message, _) = kind, let messageID = message.messageID else {
            return nil
        }

        return (inReplyTo: [messageID], references: message.references + [messageID])
    }

    /// Splits a typed recipient field.
    ///
    /// Commas and semicolons both, because people paste from everywhere.
    func recipients(from field: String) -> [EmailAddress] {
        field
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("@") }
            .map { EmailAddress(email: $0) }
    }
}

extension ComposeModel.Kind: Identifiable {
    /// Stable enough to drive a sheet: what is being written, and about what.
    public var id: String {
        switch self {
        case .new: "new"
        case .reply(let message, let all): "reply-\(all)-\(message.id)"
        case .forward(let message): "forward-\(message.id)"
        }
    }
}
