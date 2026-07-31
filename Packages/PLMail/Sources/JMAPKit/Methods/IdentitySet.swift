/// `Identity/set` (RFC 8621 §6.3) — for the one property plMail will take.
///
/// The spec's Identity carries `name`, `replyTo`, `bcc`, `textSignature` and
/// `htmlSignature`. plMail stores an Identity as an `EmailAlias` row, which has
/// an address and a display name and nowhere to put the rest, and its
/// `Identity/set` **rejects** the others rather than accepting and dropping
/// them — a client that thought it had saved a signature would go on sending
/// mail without one and never be told.
///
/// So this deliberately exposes only the rename. Modelling the full patch and
/// letting the server refuse it would put the failure in front of the user at
/// the moment they press Save, which is the wrong place to discover that a
/// field was never storable.
public struct IdentitySet: JMAPMethod {
    public static let name = "Identity/set"
    public static let capability = Capability.submission

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        /// Keyed by identity id. A `nil` name clears it back to the account's
        /// own; the server writes an empty string, which `Identity/get` then
        /// reports as the account name.
        public var update: [IdentityID: NamePatch]
        public var ifInState: StateToken?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case update, ifInState
        }
    }

    /// A patch object with exactly one settable key.
    public struct NamePatch: Encodable, Sendable, Hashable {
        public var name: String

        public init(name: String) {
            self.name = name
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var oldState: StateToken?
        public var newState: StateToken?
        public var updated: [IdentityID: JSONValue]?
        public var notUpdated: [IdentityID: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case oldState, newState, updated, notUpdated
        }
    }

    public var arguments: Arguments

    public init(
        accountID: AccountID, update: [IdentityID: NamePatch], ifInState: StateToken? = nil
    ) {
        arguments = Arguments(accountID: accountID, update: update, ifInState: ifInState)
    }

    /// Renames one identity.
    public static func rename(
        _ id: IdentityID, to name: String, accountID: AccountID
    ) -> IdentitySet {
        IdentitySet(accountID: accountID, update: [id: NamePatch(name: name)])
    }
}
