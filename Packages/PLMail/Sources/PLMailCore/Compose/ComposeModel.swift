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
        /// Carrying on with a draft. The id rather than a snapshot: the list
        /// row knows which message it is but has not loaded its body, and a
        /// composer that opened with an empty body and filled in a moment
        /// later would look like it had lost the text.
        case editDraft(emailID: String)
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
    /// What someone actually typed, formatting and all.
    ///
    /// The quoted original is deliberately **not** in here — see
    /// ``quotedHTML``.
    public var body = AttributedString()
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

    /// The original being replied to or forwarded, as HTML, kept out of the
    /// editor.
    ///
    /// Gmail's arrangement, and for Gmail's reason: a real message's HTML is
    /// tables, inline styles and images, and parsing it into an editable
    /// rich-text buffer to put it on screen would mangle it — every quote would
    /// come back subtly worse than it went in. Held aside verbatim, it is
    /// appended untouched at send time, so what the recipient sees quoted is
    /// byte-for-byte what arrived.
    public private(set) var quotedHTML: String?

    /// Drops the quoted original.
    public func removeQuote() {
        quotedHTML = nil
    }

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
    private let outbox: Outbox
    /// Asks the sender to try now. Separate from the outbox itself because
    /// draining is main-actor work that touches observable state.
    private let onQueued: @MainActor () -> Void
    private let logger = Logger(subsystem: "de.plmail", category: "compose")
    private var sendTask: Task<Void, Never>?
    /// Guards against a second identity refresh appending the signature twice.
    private var hasSignature = false

    /// Long enough to catch the "wait, wrong person" moment, short enough that
    /// nobody wonders whether it went.
    private let undoWindow = 5

    public init(
        kind: Kind,
        accountKey: String,
        accountID: AccountID,
        client: JMAPClient,
        store: SyncStore,
        outbox: Outbox,
        onQueued: @escaping @MainActor () -> Void = {}
    ) {
        self.kind = kind
        self.accountKey = accountKey
        self.accountID = accountID
        self.client = client
        self.store = store
        self.outbox = outbox
        self.onQueued = onQueued

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
        // Before the identity work: a draft carries its own recipients and
        // body, and overwriting them with a prefill would be worse than a
        // slow open.
        await loadDraftIfNeeded()

        identities = (try? await store.identities(accountKey: accountKey)) ?? []
        selectedIdentity = selectedIdentity ?? identities.first
        applySignature(of: selectedIdentity)
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
            applySignature(of: selectedIdentity)
        } catch {
            logger.error("Could not refresh identities: \(error, privacy: .public)")
        }
    }

    /// The draft being continued, once its body is in the store.
    private var editingEmailID: String? {
        guard case .editDraft(let emailID) = kind else { return nil }

        return emailID
    }

    /// Reads an existing draft back into the composer.
    ///
    /// Goes through the reader's own loader path, so the body is fetched if it
    /// is not cached — a draft written on another device has a row here long
    /// before it has a body.
    private func loadDraftIfNeeded() async {
        guard let editingEmailID else { return }

        if let cached = try? await store.message(emailID: editingEmailID, accountKey: accountKey),
            cached.hasBody
        {
            apply(cached)

            return
        }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let get = builder.add(
                EmailGet(
                    accountID: accountID,
                    ids: .value([EmailID(editingEmailID)]),
                    properties: EmailGet.readerProperties,
                    fetchTextBodyValues: true,
                    fetchHTMLBodyValues: true
                )
            )

            let results = try await client.send(builder)

            try await store.storeReaderContent(
                try results.result(of: get).list, accountKey: accountKey)

            if let loaded = try? await store.message(
                emailID: editingEmailID, accountKey: accountKey)
            {
                apply(loaded)
            }
        } catch {
            status = .failed("Couldn't open this draft.")
            logger.error("Draft load failed: \(error, privacy: .public)")
        }
    }

    /// Adds the identity's signature, once.
    ///
    /// Above the quoted original on a reply, which is where every mail client
    /// puts it and where it is actually read; at the end of a new message.
    /// Never on a draft being continued — that text already contains whatever
    /// signature it was written with, and appending again would stack them.
    private func applySignature(of identity: IdentitySnapshot?) {
        guard hasSignature == false,
            editingEmailID == nil,
            let signature = identity?.textSignature,
            signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return }

        // Always at the end of what was typed. On a reply that is still above
        // the quote, because the quote is not in the editor at all.
        body.append(AttributedString("\n\n-- \n" + signature))

        hasSignature = true
    }

    private func apply(_ draft: MessageSnapshot) {
        to = draft.to.map(\.email).joined(separator: ", ")
        cc = draft.cc.map(\.email).joined(separator: ", ")
        subject = draft.subject ?? ""

        // HTML first: a draft written here or in the web composer is HTML, and
        // reading its text alternative back would quietly strip the formatting
        // every time someone reopened it.
        if let html = draft.htmlBody {
            let split = MailHTML.splitQuote(fromHTML: html)

            body = MailHTML.attributedString(fromHTML: split.body)
            quotedHTML = split.quote
        } else {
            body = AttributedString(draft.textBody ?? draft.preview)
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
            quotedHTML = Self.quote(message)

        case .forward(let message):
            subject = Self.forwardSubject(message.subject)
            quotedHTML = Self.quote(message)

        case .editDraft:
            // Nothing to guess: `load()` reads the real thing.
            break
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
        MailHTML.quote(
            author: message.displayName,
            date: message.receivedAt,
            html: message.htmlBody,
            text: message.textBody ?? message.preview
        )
    }

    /// What goes on the wire: what was typed, then the quote.
    var outgoingHTML: String {
        let written = MailHTML.html(from: body)

        guard let quotedHTML else { return written }

        return written + "<div><br></div>" + quotedHTML
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

    /// Queues the message and asks the outbox to send it.
    ///
    /// Always queued first, even when the server is right there. The previous
    /// version sent directly and, when the request failed, told the user "the
    /// message is saved as a draft" — which was false: the draft creation *was*
    /// the request that failed, so dismissing the composer lost the text. For a
    /// mail client whose server is somebody's NAS, being unreachable is a
    /// normal Tuesday, and it must not be the way mail disappears.
    ///
    /// Writing to disk before sending also means the message survives the app
    /// being killed mid-send, which no amount of retry logic in memory does.
    private func deliver(identity: IdentitySnapshot) async {
        let queued = Outbox.PendingMessage(
            accountKey: accountKey,
            accountID: accountID,
            identityID: identity.id,
            from: identity.address,
            to: recipients(from: to),
            cc: recipients(from: cc),
            bcc: recipients(from: bcc),
            subject: subject,
            body: MailHTML.plainText(from: body),
            html: outgoingHTML,
            inReplyTo: replyTargets?.inReplyTo,
            references: replyTargets?.references,
            editingEmailID: editingEmailID,
            attachments: attachments.map {
                Outbox.Attachment(name: $0.name, type: $0.type, data: $0.data)
            }
        )

        do {
            try await outbox.enqueue(queued)
        } catch {
            // Nowhere left to put it. Keeping the composer open with the text
            // intact is the only honest response.
            status = .failed("Couldn't save this message. Don't close the composer yet.")
            logger.error("Outbox enqueue failed: \(error, privacy: .public)")

            return
        }

        // Closes immediately. The send happens in the outbox, which outlives
        // this sheet — waiting here would make an offline send look like a
        // hang, and the message is already safe on disk.
        onQueued()
        status = .sent
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
        case .editDraft(let emailID): "draft-\(emailID)"
        }
    }
}
