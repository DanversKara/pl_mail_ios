/// `Thread/set` — a **plMail extension**, not RFC 8621.
///
/// The spec's Thread is read-only, because a thread is derived from its Emails
/// and has no state of its own. plMail's has exactly one piece: a snooze. It
/// lives on the thread rather than on any message, the web UI already reads and
/// writes it, and a client that kept snooze locally instead would silently
/// disagree with the browser and lose it on reinstall.
///
/// Only `update`, and only `snoozedUntil`: the server refuses `create` and
/// `destroy` outright, since threads come into being by mail arriving.
public struct ThreadSet: JMAPMethod {
    public static let name = "Thread/set"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        /// Patch objects keyed by thread id. A `nil` value inside one clears
        /// the snooze — the same convention the rest of the API uses for
        /// removal.
        public var update: [ThreadID: Patch]

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case update
        }
    }

    public struct Patch: Encodable, Sendable {
        public var snoozedUntil: UTCDate?

        /// Hand-rolled so an absent snooze encodes as an explicit `null`
        /// rather than being omitted. Omitting it would mean "change nothing",
        /// which is the opposite of clearing a snooze.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(snoozedUntil, forKey: .snoozedUntil)
        }

        private enum CodingKeys: String, CodingKey {
            case snoozedUntil
        }

        public init(snoozedUntil: UTCDate?) {
            self.snoozedUntil = snoozedUntil
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var oldState: StateToken?
        public var newState: StateToken
        public var updated: [ThreadID: JSONValue]?
        public var notUpdated: [ThreadID: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case oldState, newState, updated, notUpdated
        }
    }

    public var arguments: Arguments

    public init(accountID: AccountID, update: [ThreadID: Patch]) {
        arguments = Arguments(accountID: accountID, update: update)
    }

    /// Snoozes or wakes one conversation.
    public static func snooze(
        _ threadID: ThreadID, until: UTCDate?, accountID: AccountID
    ) -> ThreadSet {
        ThreadSet(accountID: accountID, update: [threadID: Patch(snoozedUntil: until)])
    }
}
