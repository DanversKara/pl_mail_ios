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
