import Foundation

/// BearerMail: `Identity/set` with a create — a new alias to send from.
///
/// The same call the Android app's quick alias makes. The server accepts
/// `email` (which must be on the account's own domain) and `name`, and
/// answers the new identity's id in `created`, or the reason in `notCreated`.
public struct IdentityCreate: JMAPMethod {
    public static let name = "Identity/set"
    public static let capability = Capability.submission
    public static let creationID = "alias"

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var email: String
        public var displayName: String?

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: JMAPCodingKey.self)
            try c.encode(accountID, forKey: JMAPCodingKey("accountId"))
            var object: [String: String] = ["email": email]
            if let displayName, displayName.isEmpty == false { object["name"] = displayName }
            try c.encode([IdentityCreate.creationID: object], forKey: JMAPCodingKey("create"))
        }
    }

    public struct Result: Decodable, Sendable {
        public var created: [String: JSONValue]?
        public var notCreated: [String: JSONValue]?

        /// The server's own words for a refusal, when it gave any.
        public var refusal: String? {
            guard let failure = notCreated?[IdentityCreate.creationID] else { return nil }
            return failure.objectValue?["description"]?.stringValue
                ?? failure.objectValue?["type"]?.stringValue
                ?? "refused"
        }
    }

    public var arguments: Arguments

    public init(accountID: AccountID, email: String, displayName: String? = nil) {
        arguments = Arguments(accountID: accountID, email: email, displayName: displayName)
    }
}
