/// `Mailbox/set` (RFC 8621 §2.5) — create, rename, re-parent and destroy
/// labels.
///
/// plMail implements this in full, so unlike ``IdentitySet`` there is nothing
/// to hold back: `name`, `parentId`, `isSubscribed` and `sortOrder` are all
/// settable, and destroy works on any label the user made.
///
/// The server's rules, which the UI has to respect *before* sending rather than
/// discover from a refusal:
///
/// - **System labels are immutable.** Anything with a ``MailboxRole`` maps onto
///   a provider built-in like INBOX, which no API can rename or delete.
///   `Mailbox/get` says so in ``MailboxRights/mayRename`` and
///   ``MailboxRights/mayDelete``; trust those rather than inferring from `role`,
///   because the server is the one that decides.
/// - **A name may not contain `/`.** Gmail encodes hierarchy in the name, so a
///   slash in a leaf name would silently create a nested label on the provider.
///   Use ``parentID`` for nesting.
/// - **Siblings must have distinct names.** Same-named children of the same
///   parent are refused with `invalidProperties`.
/// - **A label with children cannot be destroyed** (`mailboxHasChild`); the
///   children go first.
/// - **`onDestroyRemoveEmails` is refused outright**, not ignored — plMail
///   never deletes mail as a side effect of removing a label. It is therefore
///   not modelled here at all, because the only value it could carry is the one
///   the server rejects.
///
/// Destroying is per-account: a Mailbox is a label *binding*, so this
/// un-materialises the label here and leaves the user's other accounts alone.
public struct MailboxSet: JMAPMethod {
    public static let name = "Mailbox/set"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        /// Keyed by a client-chosen creation id, which the response echoes back
        /// alongside the real id the server assigned.
        public var create: [String: Creation]?
        public var update: [MailboxID: Patch]?
        public var destroy: [MailboxID]?
        public var ifInState: StateToken?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case create, update, destroy, ifInState
        }
    }

    /// A new label.
    public struct Creation: Encodable, Sendable, Hashable {
        /// The **leaf** name. May not contain `/`.
        public var name: String
        /// The parent's binding id, or nil for a top-level label.
        public var parentID: MailboxID?
        /// Whether the label shows in the sidebar. Defaults to visible, which
        /// is what someone who just typed a name into a "New label" field
        /// means — a label created hidden looks like a label that failed.
        public var isSubscribed: Bool?
        public var sortOrder: Int?

        public init(
            name: String,
            parentID: MailboxID? = nil,
            isSubscribed: Bool? = nil,
            sortOrder: Int? = nil
        ) {
            self.name = name
            self.parentID = parentID
            self.isSubscribed = isSubscribed
            self.sortOrder = sortOrder
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case parentID = "parentId"
            case isSubscribed, sortOrder
        }
    }

    /// A change to an existing label.
    ///
    /// Every field is doubly optional on the wire: absent means "leave it
    /// alone", present-and-null means "clear it". Only ``parentID`` can
    /// actually be cleared — moving a nested label back to the top level — and
    /// `nil` and "not mentioned" are different requests there, which is why
    /// this cannot be a plain `MailboxID?` encoded with the synthesised
    /// encoder: that would send `parentId: null` on every rename and silently
    /// flatten the user's hierarchy.
    public struct Patch: Encodable, Sendable, Hashable {
        public var name: String?
        /// `.some(nil)` moves the label to the top level; `nil` leaves the
        /// parent untouched.
        public var parentID: MailboxID??
        public var isSubscribed: Bool?
        public var sortOrder: Int?

        public init(
            name: String? = nil,
            parentID: MailboxID?? = nil,
            isSubscribed: Bool? = nil,
            sortOrder: Int? = nil
        ) {
            self.name = name
            self.parentID = parentID
            self.isSubscribed = isSubscribed
            self.sortOrder = sortOrder
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case parentID = "parentId"
            case isSubscribed, sortOrder
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(isSubscribed, forKey: .isSubscribed)
            try container.encodeIfPresent(sortOrder, forKey: .sortOrder)

            // The one case the synthesised encoder cannot express. An unset
            // parent must not appear as a key at all: the server treats any
            // mentioned property as a change, and `parentId: null` on a rename
            // would move the label to the top level as a side effect.
            if let parentID {
                if let parentID {
                    try container.encode(parentID, forKey: .parentID)
                } else {
                    try container.encodeNil(forKey: .parentID)
                }
            }
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var oldState: StateToken?
        public var newState: StateToken?
        /// Keyed by the *creation* id sent in ``Arguments/create``, carrying
        /// the server-assigned ``Mailbox`` — its `id` is what everything else
        /// then refers to.
        public var created: [String: Mailbox]?
        public var notCreated: [String: JSONValue]?
        public var updated: [MailboxID: JSONValue]?
        public var notUpdated: [MailboxID: JSONValue]?
        public var destroyed: [MailboxID]?
        public var notDestroyed: [MailboxID: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case oldState, newState
            case created, notCreated, updated, notUpdated, destroyed, notDestroyed
        }
    }

    public var arguments: Arguments

    public init(
        accountID: AccountID,
        create: [String: Creation]? = nil,
        update: [MailboxID: Patch]? = nil,
        destroy: [MailboxID]? = nil,
        ifInState: StateToken? = nil
    ) {
        arguments = Arguments(
            accountID: accountID,
            create: create,
            update: update,
            destroy: destroy,
            ifInState: ifInState
        )
    }

    // MARK: - The three things the app actually does

    /// The creation id used by ``create(name:parentID:accountID:)``, and the
    /// key to read the new mailbox back out of ``Result/created``.
    public static let creationID = "new"

    public static func create(
        name: String, parentID: MailboxID? = nil, accountID: AccountID
    ) -> MailboxSet {
        MailboxSet(
            accountID: accountID,
            create: [creationID: Creation(name: name, parentID: parentID)]
        )
    }

    public static func rename(
        _ id: MailboxID, to name: String, accountID: AccountID
    ) -> MailboxSet {
        MailboxSet(accountID: accountID, update: [id: Patch(name: name)])
    }

    public static func destroy(_ id: MailboxID, accountID: AccountID) -> MailboxSet {
        MailboxSet(accountID: accountID, destroy: [id])
    }
}
