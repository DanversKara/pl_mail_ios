import Foundation

/// The JMAP Session object (RFC 8620 §2).
///
/// **Everything else is discovered from here.** `apiUrl`, `uploadUrl`,
/// `downloadUrl` and `eventSourceUrl` must be read out of this object on every
/// connection and never reconstructed from the server address — plMail is
/// self-hosted and may live behind a reverse proxy on any path.
public struct Session: Hashable, Sendable, Decodable {
    public var capabilities: Capabilities

    /// One JMAP account per **connected mail account**, keyed by account id.
    ///
    /// A user with a work Gmail, a personal IMAP and an Outlook account sees
    /// three accounts under one login. There is no server-side cross-account
    /// query, so a unified inbox is a client-side merge of one query per
    /// account, ordered by `receivedAt`.
    public var accounts: [AccountID: SessionAccount]

    public var primaryAccounts: [String: AccountID]
    public var username: String
    public var apiURL: URL
    public var downloadURL: URLTemplate
    public var uploadURL: URLTemplate
    public var eventSourceURL: URLTemplate
    public var state: StateToken

    private enum CodingKeys: String, CodingKey {
        case capabilities, accounts, primaryAccounts, username
        case apiURL = "apiUrl"
        case downloadURL = "downloadUrl"
        case uploadURL = "uploadUrl"
        case eventSourceURL = "eventSourceUrl"
        case state
    }

    /// The account to open on first launch, when the user has not chosen.
    public var primaryMailAccountID: AccountID? {
        primaryAccounts[Capability.mail.rawValue]
    }

    /// Accounts in a stable order, since the wire form is a dictionary.
    public var orderedAccounts: [(id: AccountID, account: SessionAccount)] {
        accounts
            .map { (id: $0.key, account: $0.value) }
            .sorted {
                $0.account.name.localizedStandardCompare($1.account.name) == .orderedAscending
            }
    }
}

extension Session {
    public struct Capabilities: Hashable, Sendable, Decodable {
        public var core: CoreCapabilities
        /// A plMail extension carrying the VAPID key. Advertised here, but
        /// **never declarable in `using`** — see ``Capability``.
        public var push: PushCapabilities?

        private enum CodingKeys: String, CodingKey {
            case core = "urn:ietf:params:jmap:core"
            case push = "urn:plmail:params:jmap:push"
        }
    }

    public struct CoreCapabilities: Hashable, Sendable, Decodable {
        public var maxSizeUpload: Int
        public var maxConcurrentUpload: Int
        public var maxSizeRequestObject: Int
        public var maxConcurrentRequests: Int
        public var maxCallsInRequest: Int
        public var maxObjectsInGet: Int
        public var maxObjectsInSet: Int
        public var collationAlgorithms: [String]
    }

    public struct PushCapabilities: Hashable, Sendable, Decodable {
        /// An empty key means Web Push is unconfigured on this instance —
        /// don't offer it.
        public var vapidPublicKey: String

        public var isConfigured: Bool { vapidPublicKey.isEmpty == false }
    }
}

/// One connected mail account.
public struct SessionAccount: Hashable, Sendable, Decodable {
    /// The mail address. Shown to the user wherever accounts are listed.
    public var name: String
    public var isPersonal: Bool
    public var isReadOnly: Bool
    public var accountCapabilities: AccountCapabilities

    public struct AccountCapabilities: Hashable, Sendable, Decodable {
        public var mail: MailCapabilities?

        private enum CodingKeys: String, CodingKey {
            case mail = "urn:ietf:params:jmap:mail"
        }
    }

    public struct MailCapabilities: Hashable, Sendable, Decodable {
        public var maxMailboxesPerEmail: Int?
        public var maxMailboxDepth: Int?
        public var maxSizeMailboxName: Int?
        public var maxSizeAttachmentsPerEmail: Int?
        public var emailQuerySortOptions: [String]?
        public var mayCreateTopLevelMailbox: Bool?
    }
}

/// A URI template from the Session object, e.g.
/// `…/jmap/download/{accountId}/{blobId}/{name}?accept={type}`.
///
/// Deliberately not a `URL`: the raw form is not a valid URL until its
/// variables are filled in, and keeping it as a distinct type stops it being
/// passed to something that expects a usable address.
public struct URLTemplate: Hashable, Sendable, Decodable, CustomStringConvertible {
    public let template: String

    public init(_ template: String) {
        self.template = template
    }

    public init(from decoder: any Decoder) throws {
        template = try decoder.singleValueContainer().decode(String.self)
    }

    public var description: String { template }

    /// Substitutes `{name}` variables, percent-encoding each value.
    ///
    /// Unfilled variables are left in place rather than removed, so a missing
    /// one shows up as an obviously broken URL instead of a subtly wrong one.
    public func expanded(_ variables: [String: String]) -> URL? {
        var result = template

        for (name, value) in variables {
            let encoded =
                value.addingPercentEncoding(withAllowedCharacters: .jmapTemplateValue) ?? value
            result = result.replacingOccurrences(of: "{\(name)}", with: encoded)
        }

        return URL(string: result)
    }
}

extension CharacterSet {
    /// Path-segment-safe: `/` must be encoded, or a blob id or filename
    /// containing one would silently change the request path.
    fileprivate static let jmapTemplateValue: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
