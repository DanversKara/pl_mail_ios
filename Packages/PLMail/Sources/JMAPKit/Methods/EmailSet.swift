/// `Email/set`, for the mutations this client makes.
///
/// Every change goes through the same propagator the web UI uses, so archiving
/// from the app archives in Gmail, IMAP or Graph exactly as archiving in the
/// browser does.
///
/// Two semantics are easy to get wrong and are encoded here rather than left
/// to call sites:
///
/// - **Archive means removing the Inbox mailbox**, not adding an Archive one.
///   "Archived" in plMail's model is *carries no Inbox label*; the Archive
///   label is IMAP bookkeeping for plain-IMAP accounts and is hidden by
///   default.
/// - **`destroy` is a move to Trash**, not a row delete. There is no
///   hard-delete path anywhere in the product, and the UI should say Trash.
public struct EmailSet: JMAPMethod {
    public static let name = "Email/set"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        /// Patch objects keyed by email id. Patch paths rather than whole
        /// objects: sending a complete `keywords` map to set `$seen` would
        /// clear `$flagged` as a side effect.
        public var update: [EmailID: [String: PatchValue]]
        /// Presented as Trash in the UI, because that is what it does.
        public var destroy: [EmailID]?
        /// Conflict detection, honoured by the server.
        public var ifInState: StateToken?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case update, destroy, ifInState
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var oldState: StateToken?
        public var newState: StateToken
        public var updated: [EmailID: JSONValue]?
        public var notUpdated: [EmailID: JSONValue]?
        public var destroyed: [EmailID]?
        public var notDestroyed: [EmailID: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case oldState, newState, updated, notUpdated, destroyed, notDestroyed
        }
    }

    public var arguments: Arguments

    public init(
        accountID: AccountID, update: [EmailID: [String: PatchValue]] = [:],
        destroy: [EmailID]? = nil, ifInState: StateToken? = nil
    ) {
        arguments = Arguments(
            accountID: accountID,
            update: update,
            destroy: destroy?.isEmpty == true ? nil : destroy,
            ifInState: ifInState
        )
    }
}

/// What a patch path can be set to.
///
/// `null` removes rather than sets — which is how a mailbox is *left*, and the
/// reason this is not simply a `Bool`.
public enum PatchValue: Hashable, Sendable, Encodable {
    case set
    case remove

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .set: try container.encode(true)
        case .remove: try container.encodeNil()
        }
    }
}

extension EmailSet {
    /// Patch paths, built rather than spelled out at call sites.
    public enum Patch {
        public static func keyword(_ keyword: Keyword) -> String {
            precondition(
                keyword.isSupported,
                "plMail supports only $seen, $flagged, $draft and $answered."
            )

            return "keywords/\(keyword.rawValue)"
        }

        public static func mailbox(_ id: MailboxID) -> String {
            "mailboxIds/\(id.rawValue)"
        }
    }

    /// Marks messages read or unread.
    public static func setSeen(
        _ isSeen: Bool, ids: [EmailID], accountID: AccountID
    ) -> EmailSet {
        patch([Patch.keyword(.seen): isSeen ? .set : .remove], ids: ids, accountID: accountID)
    }

    /// Stars or unstars.
    public static func setFlagged(
        _ isFlagged: Bool, ids: [EmailID], accountID: AccountID
    ) -> EmailSet {
        patch(
            [Patch.keyword(.flagged): isFlagged ? .set : .remove], ids: ids, accountID: accountID)
    }

    /// Archives: leaves the Inbox, and joins Archive in the same patch.
    ///
    /// Both halves are required. RFC 8621 says an Email must belong to at
    /// least one Mailbox, so removing Inbox from a message that is *only* in
    /// the Inbox is refused with `invalidProperties` — which is most mail.
    /// Adding Archive in the same patch keeps the invariant and matches what
    /// archiving means everywhere else: out of the inbox, still findable.
    ///
    /// `archive` is optional because an account may not have that binding, in
    /// which case the message's other labels are what keep it valid.
    public static func archive(
        ids: [EmailID], inbox: MailboxID, archive: MailboxID?, accountID: AccountID
    ) -> EmailSet {
        var patch: [String: PatchValue] = [Patch.mailbox(inbox): .remove]

        if let archive { patch[Patch.mailbox(archive)] = .set }

        return self.patch(patch, ids: ids, accountID: accountID)
    }

    /// Puts back into the Inbox — the undo of archiving or trashing.
    ///
    /// Leaves Archive as well when one was added, so undo restores the state
    /// that existed rather than a new one.
    public static func moveToInbox(
        ids: [EmailID], inbox: MailboxID, leaving archive: MailboxID? = nil,
        accountID: AccountID
    ) -> EmailSet {
        var patch: [String: PatchValue] = [Patch.mailbox(inbox): .set]

        if let archive { patch[Patch.mailbox(archive)] = .remove }

        return self.patch(patch, ids: ids, accountID: accountID)
    }

    /// Moves to Trash. Recoverable: nothing in this product hard-deletes.
    public static func trash(ids: [EmailID], accountID: AccountID) -> EmailSet {
        EmailSet(accountID: accountID, destroy: ids)
    }

    private static func patch(
        _ patch: [String: PatchValue], ids: [EmailID], accountID: AccountID
    ) -> EmailSet {
        EmailSet(
            accountID: accountID,
            update: Dictionary(uniqueKeysWithValues: ids.map { ($0, patch) })
        )
    }
}
