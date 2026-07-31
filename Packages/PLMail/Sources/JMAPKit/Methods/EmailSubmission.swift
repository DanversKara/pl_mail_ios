/// Creating a draft with `Email/set create`.
///
/// Goes through the same draft writer the web composer uses, so a draft made
/// here is the same object the browser would have made.
public struct EmailCreate: JMAPMethod {
    public static let name = "Email/set"
    public static let capability = Capability.mail

    public struct Draft: Encodable, Sendable {
        public var mailboxIDs: JMAPIDSet<MailboxID>
        public var keywords: KeywordSet
        public var from: [EmailAddress]?
        public var to: [EmailAddress]?
        public var cc: [EmailAddress]?
        public var bcc: [EmailAddress]?
        public var subject: String?
        /// Threading is by RFC Message-ID, so a reply that omits these starts
        /// a new conversation instead of continuing one.
        public var inReplyTo: [String]?
        public var references: [String]?
        /// The part list, **not** `bodyStructure`.
        ///
        /// RFC 8621 allows either, but the server's draft writer reads
        /// `textBody`/`htmlBody` and keys them into `bodyValues`. Sending
        /// `bodyStructure` instead is silently ignored — the draft is created
        /// with everything else intact and no body at all, which looks like
        /// the text was lost rather than never read.
        public var textBody: [BodyPart]?
        public var bodyValues: [String: BodyValue]?

        private enum CodingKeys: String, CodingKey {
            case mailboxIDs = "mailboxIds"
            case keywords, from, to, cc, bcc, subject, inReplyTo, references
            case textBody, bodyValues
        }

        public init(
            drafts: MailboxID,
            from: EmailAddress?,
            to: [EmailAddress],
            cc: [EmailAddress] = [],
            bcc: [EmailAddress] = [],
            subject: String,
            text: String,
            inReplyTo: [String]? = nil,
            references: [String]? = nil
        ) {
            mailboxIDs = JMAPIDSet([drafts])
            // The draft keyword is what makes the row open the composer rather
            // than the reader, in this client and in the web UI.
            keywords = KeywordSet([.draft])
            self.from = from.map { [$0] }
            self.to = to.isEmpty ? nil : to
            self.cc = cc.isEmpty ? nil : cc
            self.bcc = bcc.isEmpty ? nil : bcc
            self.subject = subject
            self.inReplyTo = inReplyTo
            self.references = references

            var part = BodyPart()
            part.partID = "text"
            part.type = "text/plain"
            textBody = [part]
            bodyValues = ["text": BodyValue(value: text)]
        }
    }

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        /// Keyed by a creation id, which later calls in the same request refer
        /// to as `#id` — this is how a draft is created and submitted in one
        /// round trip.
        public var create: [String: Draft]

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case create
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var newState: StateToken
        public var created: [String: CreatedEmail]?
        public var notCreated: [String: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case newState, created, notCreated
        }
    }

    public struct CreatedEmail: Decodable, Sendable {
        public var id: EmailID
        public var blobID: BlobID?
        public var threadID: ThreadID?

        private enum CodingKeys: String, CodingKey {
            case id
            case blobID = "blobId"
            case threadID = "threadId"
        }
    }

    public var arguments: Arguments

    public static let creationID = "draft"

    public init(accountID: AccountID, draft: Draft) {
        arguments = Arguments(accountID: accountID, create: [Self.creationID: draft])
    }
}

/// Sending, with `EmailSubmission/set`.
///
/// Queued on the same message bus the web composer uses: that pipeline does
/// the whole draft-to-sent transition itself — adds Sent, removes Drafts,
/// clears the draft flag, sets `sentAt` — so a client that omits
/// `onSuccessUpdateEmail` still ends up correct.
///
/// Two things to know. `undoStatus` comes back as `pending` because the send
/// genuinely has not happened yet. And **the web UI's undo-send grace period
/// is deliberately not applied to JMAP submissions** — a JMAP client asked to
/// send now. An undo window here is this client's own, implemented by delaying
/// the call.
public struct EmailSubmissionSet: JMAPMethod {
    public static let name = "EmailSubmission/set"
    public static let capability = Capability.submission

    public struct Submission: Encodable, Sendable {
        /// May be a `#creationId` referring to a draft created in the same
        /// request.
        public var emailID: String
        public var identityID: IdentityID

        private enum CodingKeys: String, CodingKey {
            case emailID = "emailId"
            case identityID = "identityId"
        }
    }

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var create: [String: Submission]

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case create
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var newState: StateToken
        public var created: [String: JSONValue]?
        public var notCreated: [String: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case newState, created, notCreated
        }
    }

    public var arguments: Arguments

    public init(accountID: AccountID, emailID: String, identityID: IdentityID) {
        arguments = Arguments(
            accountID: accountID,
            create: ["send": Submission(emailID: emailID, identityID: identityID)]
        )
    }
}
