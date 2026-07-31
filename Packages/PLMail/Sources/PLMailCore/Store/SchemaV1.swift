import Foundation
import JMAPKit
import SwiftData

// MARK: - The rule this whole schema depends on
//
// EVERYTHING HERE IS A CACHE. Every row is reconstructible from the server, and
// nothing may be stored here that isn't. The only irreplaceable state the app
// holds is the server address and credential, which live in the Keychain, plus
// local preferences in UserDefaults.
//
// That is a constraint, not an observation. It buys the recovery strategy in
// `MailStack`: on any migration or corruption failure, delete the store and
// re-sync. Which means no custom migration stage ever has to be written for
// cache data — and it stays true only as long as nobody adds a column holding
// something the server doesn't know about. If you find yourself wanting to,
// that is the signal to ask for a server change instead.

public enum SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            StoredAccount.self,
            StoredMailbox.self,
            StoredThread.self,
            StoredEmail.self,
            StoredEmailBody.self,
            StoredAttachment.self,
            StoredFeedEntry.self,
            StoredFeedCursor.self,
            StoredIdentity.self,
        ]
    }
}

/// Identity across the store.
///
/// JMAP ids are unique only *within* an account, and one login reaches several
/// accounts, so every row is keyed by a composite. `accountKey` is the
/// server-plus-account prefix; `uid` appends the object's own id.
public enum StoreKey {
    public static func account(server: String, account: AccountID) -> String {
        "\(server)/\(account.rawValue)"
    }

    public static func object(accountKey: String, id: String) -> String {
        "\(accountKey)#\(id)"
    }
}

// MARK: - Account

@Model
public final class StoredAccount {
    #Unique<StoredAccount>([\.uid])

    public var uid: String = ""
    public var serverID: String = ""
    /// The JMAP account id. Always a string on the wire.
    public var accountID: String = ""
    /// The mail address, as the server reports it.
    public var name: String = ""
    public var isPersonal: Bool = true
    public var isReadOnly: Bool = false
    public var sortIndex: Int = 0

    // One sync cursor per JMAP object type. `"0"` is always answerable, so a
    // fresh account starts there rather than at nil-meaning-everything.
    public var emailState: String?
    public var threadState: String?
    public var mailboxState: String?

    public var lastSyncedAt: Date?
    /// The last failure, kept so the diagnostics screen can show it. Users
    /// self-host: when something breaks they are the one who has to fix it.
    public var lastSyncError: String?

    public init(uid: String, serverID: String, accountID: String, name: String) {
        self.uid = uid
        self.serverID = serverID
        self.accountID = accountID
        self.name = name
    }

    public var accountKey: String { uid }
}

// MARK: - Mailbox

@Model
public final class StoredMailbox {
    #Unique<StoredMailbox>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""

    /// The JMAP Mailbox id — a per-account label *binding* id.
    public var mailboxID: String = ""
    /// The user-scoped label id, from plMail's `labelId` extension. Distinct
    /// from ``mailboxID`` and never accepted as input anywhere; it exists so
    /// one label across several accounts can collapse into one sidebar row.
    public var labelID: String?

    /// Leaf name only. Hierarchy is expressed through ``parentID``.
    public var name: String = ""
    public var parentID: String?
    public var role: String?
    public var sortOrder: Int = 0

    public var totalEmails: Int = 0
    public var unreadEmails: Int = 0
    public var totalThreads: Int = 0
    public var unreadThreads: Int = 0

    public var isSubscribed: Bool = true
    public var mayRename: Bool = false
    public var mayDelete: Bool = false

    public init(uid: String, accountKey: String, mailboxID: String, name: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.mailboxID = mailboxID
        self.name = name
    }
}

// MARK: - Thread

@Model
public final class StoredThread {
    #Unique<StoredThread>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""
    public var threadID: String = ""
    public var emailIDs: [String] = []

    // Denormalised list-row fields, recomputed on every write.
    //
    // Load-bearing, not an optimisation: the unified inbox sorts across
    // accounts on `latestReceivedAt` with no joins and no faults. Recomputing
    // these on write is cheap; deriving them on read for fifty rows at 120fps
    // is not.
    public var latestReceivedAt: Date = Date.distantPast
    public var subject: String?
    public var participantsSummary: String = ""
    public var snippet: String = ""
    public var messageCount: Int = 1
    public var isUnread: Bool = false
    public var isFlagged: Bool = false
    public var hasAttachment: Bool = false

    public init(uid: String, accountKey: String, threadID: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.threadID = threadID
    }
}

// MARK: - Email

@Model
public final class StoredEmail {
    #Unique<StoredEmail>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""
    public var emailID: String = ""
    public var threadID: String?
    public var blobID: String?

    /// Nullable to match the wire type. The server falls back through
    /// `receivedAt ?? sentAt ?? createdAt` so it is in practice always set —
    /// but any sort must put nils last rather than assume.
    public var receivedAt: Date?
    public var sentAt: Date?

    public var subject: String?
    public var fromName: String?
    public var fromAddress: String?
    /// `[EmailAddress]` as JSON. Recipients are shown but never queried on, so
    /// a blob costs nothing and keeps the schema from growing three tables.
    public var toJSON: Data?
    public var ccJSON: Data?
    public var bccJSON: Data?

    public var preview: String = ""
    public var size: Int = 0

    public var isSeen: Bool = false
    public var isFlagged: Bool = false
    public var isDraft: Bool = false
    public var isAnswered: Bool = false
    public var hasAttachment: Bool = false

    /// Mailbox (binding) ids this message is in.
    public var mailboxIDs: [String] = []

    /// Separate model so list-driving fetches never fault a 400KB HTML string
    /// into memory, and so bodies can be evicted without touching this row.
    @Relationship(deleteRule: .cascade)
    public var body: StoredEmailBody?

    @Relationship(deleteRule: .cascade)
    public var attachments: [StoredAttachment] = []

    public init(uid: String, accountKey: String, emailID: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.emailID = emailID
    }
}

@Model
public final class StoredEmailBody {
    #Unique<StoredEmailBody>([\.uid])

    public var uid: String = ""
    public var textBody: String?
    /// Always the server's sanitised HTML. Render it on a permanently light
    /// background regardless of theme.
    public var htmlBody: String?
    public var fetchedAt: Date = Date.distantPast

    public init(uid: String) {
        self.uid = uid
    }
}

@Model
public final class StoredAttachment {
    #Unique<StoredAttachment>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""
    public var partID: String = ""
    /// Opaque and namespaced server-side. Never parsed.
    public var blobID: String = ""
    public var name: String?
    public var type: String = "application/octet-stream"
    public var size: Int = 0
    public var cid: String?
    public var isInline: Bool = false

    public init(uid: String, accountKey: String, partID: String, blobID: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.partID = partID
        self.blobID = blobID
    }
}

// MARK: - Feed

/// One row of a materialised, ordered list.
///
/// Not the same thing as "every thread I have cached". A `@Query` over
/// ``StoredThread`` sorted by date would show every thread from every mailbox;
/// this table is the persisted answer to *this particular list, as far down as
/// I have paged*, which is what makes the list instant on cold launch and keeps
/// scroll position stable across a refresh.
@Model
public final class StoredFeedEntry {
    #Unique<StoredFeedEntry>([\.uid])

    public var uid: String = ""
    public var feedID: String = ""
    public var sortDate: Date = Date.distantPast
    public var accountKey: String = ""
    public var threadID: String = ""
    /// The newest email in the thread — the one the row renders from.
    public var emailID: String = ""

    public init(
        uid: String, feedID: String, sortDate: Date, accountKey: String,
        threadID: String, emailID: String
    ) {
        self.uid = uid
        self.feedID = feedID
        self.sortDate = sortDate
        self.accountKey = accountKey
        self.threadID = threadID
        self.emailID = emailID
    }
}

/// How deep one account has been paged within one feed.
@Model
public final class StoredFeedCursor {
    #Unique<StoredFeedCursor>([\.uid])

    public var uid: String = ""
    public var feedID: String = ""
    public var accountKey: String = ""

    /// The `receivedAt` of the last row emitted. The next page asks for
    /// everything strictly before it.
    public var lastSortDate: Date?
    /// Ids already emitted at exactly ``lastSortDate``.
    ///
    /// `before` is a strict `<`, so messages sharing one second across a page
    /// boundary would be dropped. The next page asks for `before:
    /// lastSortDate + 1s` and filters these out.
    public var boundaryIDs: [String] = []
    public var isExhausted: Bool = false

    public init(uid: String, feedID: String, accountKey: String) {
        self.uid = uid
        self.feedID = feedID
        self.accountKey = accountKey
    }
}

// MARK: - Identity

/// Populated now, unused until compose — one extra call, and it tells the UI
/// which addresses are "me" so a participant list can elide the user.
@Model
public final class StoredIdentity {
    #Unique<StoredIdentity>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""
    public var identityID: String = ""
    public var name: String?
    public var email: String = ""

    public init(uid: String, accountKey: String, identityID: String, email: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.identityID = identityID
        self.email = email
    }
}
