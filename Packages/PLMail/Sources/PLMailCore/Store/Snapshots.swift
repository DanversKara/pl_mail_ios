import Foundation
import JMAPKit

/// Value types for crossing an actor boundary.
///
/// `@Model` classes are not `Sendable` and must never leave the actor that owns
/// their context. When the sync engine needs to *read* something the store
/// knows, it gets one of these instead of a live object.

public struct AccountSnapshot: Hashable, Sendable, Identifiable {
    public var accountKey: String
    public var accountID: AccountID
    public var name: String
    public var emailState: StateToken?
    public var threadState: StateToken?
    public var mailboxState: StateToken?

    public var id: String { accountKey }
}

public struct MailboxSnapshot: Hashable, Sendable, Identifiable {
    public var accountKey: String
    public var mailboxID: MailboxID
    public var labelID: LabelID?
    public var name: String
    public var role: MailboxRole?
    public var unreadThreads: Int
    public var totalThreads: Int

    public var id: String { "\(accountKey)#\(mailboxID.rawValue)" }
}

/// One message, as the reader needs it.
public struct MessageSnapshot: Hashable, Sendable, Identifiable {
    public var emailID: String
    public var accountKey: String
    public var blobID: String?
    public var subject: String?
    public var fromName: String?
    public var fromAddress: String?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var receivedAt: Date?
    /// Bare, angle brackets already stripped. Needed to thread a reply.
    public var messageID: String?
    public var references: [String]
    public var preview: String
    public var isSeen: Bool
    public var isFlagged: Bool
    public var isDraft: Bool

    /// Always the server's sanitised HTML. Render on a permanently light
    /// background regardless of theme.
    public var htmlBody: String?
    public var textBody: String?
    /// Whether the body has been fetched at all, as distinct from a message
    /// that genuinely has none.
    public var hasBody: Bool

    public var attachments: [AttachmentSnapshot]
    /// Referenced from the HTML by `cid:` rather than listed to the user.
    public var inlineParts: [AttachmentSnapshot]

    public var id: String { "\(accountKey)#\(emailID)" }

    public var displayName: String {
        if let fromName, fromName.isEmpty == false { return fromName }
        return fromAddress ?? "(unknown sender)"
    }
}

public struct AttachmentSnapshot: Hashable, Sendable, Identifiable {
    public var partID: String
    public var blobID: String
    public var name: String?
    public var type: String
    public var size: Int
    public var cid: String?
    public var isInline: Bool

    public var id: String { partID }

    public var displayName: String {
        guard let name, name.isEmpty == false else { return "Attachment" }
        return name
    }
}

/// A sendable address for one account.
public struct IdentitySnapshot: Hashable, Sendable, Identifiable {
    public var id: IdentityID
    public var name: String?
    public var email: String

    public var address: EmailAddress { EmailAddress(name: name, email: email) }

    public var displayName: String {
        guard let name, name.isEmpty == false else { return email }

        // An account whose stored address is really its display name — plMail
        // allows it, and a few provider imports produce it — would otherwise
        // render as "Work <Work>", which looks like a formatting bug rather
        // than the data problem it is.
        guard name != email else { return email }

        return "\(name) <\(email)>"
    }
}

/// A feed row taken out optimistically, kept so it can be put back.
public struct RemovedFeedRow: Hashable, Sendable {
    public var feedID: String
    public var sortDate: Date
    public var accountKey: String
    public var threadID: String
    public var emailID: String
}

/// One row of a materialised feed.
public struct FeedEntrySnapshot: Hashable, Sendable {
    public var accountKey: String
    public var threadID: String
    public var emailID: String
    public var sortDate: Date
}

/// Where one account's paging has reached within one feed.
public struct FeedCursorSnapshot: Hashable, Sendable {
    public var lastSortDate: Date?
    public var boundaryIDs: Set<String>
    public var isExhausted: Bool

    public init(
        lastSortDate: Date? = nil,
        boundaryIDs: Set<String> = [],
        isExhausted: Bool = false
    ) {
        self.lastSortDate = lastSortDate
        self.boundaryIDs = boundaryIDs
        self.isExhausted = isExhausted
    }
}
