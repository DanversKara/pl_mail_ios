import Foundation
import JMAPKit

/// Names one ordered list.
///
/// A feed is a (selection, filter, sort) triple, and its id is what ties the
/// rows in `StoredFeedEntry` to the list on screen. Stable across launches, so
/// a cold start shows the list it showed last time before any network call.
public enum FeedID: Hashable, Sendable {
    /// One role across every account — the unified inbox, and what the app
    /// opens on. There is no server-side cross-account query, so this is a
    /// client-side merge of one query per account.
    case unified(MailboxRole)
    /// One label across every account, tied together by plMail's `labelId`.
    case unifiedLabel(LabelID)
    /// One mailbox in one account.
    case mailbox(accountKey: String, mailboxID: MailboxID)
    /// The results of one search, across every account that can serve it.
    ///
    /// Materialised like any other feed so results page and survive a
    /// backgrounding, but pruned when the search is abandoned — a stored feed
    /// per query typed would grow without bound.
    case searchResults(query: String)

    public var rawValue: String {
        switch self {
        case .unified(let role): "unified:\(role.rawValue)"
        case .unifiedLabel(let label): "label:\(label.rawValue)"
        case .mailbox(let accountKey, let mailboxID):
            "acct:\(accountKey):mbox:\(mailboxID.rawValue)"
        case .searchResults(let query):
            "search:\(query)"
        }
    }

    /// What to show as the list's title.
    ///
    /// A role names itself. A label or a single mailbox does not — the name
    /// lives on the mailbox rows — so the caller passes them in. An untitled
    /// list reads as a rendering fault, so there is always a fallback.
    public func title(mailboxes: [MailboxSnapshot] = []) -> String {
        switch self {
        case .unified(let role):
            return role.displayName

        case .unifiedLabel(let labelID):
            return mailboxes.first { $0.labelID == labelID }?.name ?? "Label"

        case .mailbox(let accountKey, let mailboxID):
            let match = mailboxes.first {
                $0.accountKey == accountKey && $0.mailboxID == mailboxID
            }

            return match?.name ?? "Mailbox"

        case .searchResults:
            return "Results"
        }
    }
}

extension MailboxRole {
    /// Localised, and against **this module's** bundle.
    ///
    /// These are the most-read words in the app — they name every row in the
    /// sidebar and title every list — and they live in PLMailCore rather than
    /// in the view layer, so the UI module's catalogue never sees them. A
    /// `String(localized:)` without the bundle would look up in the app, miss,
    /// and silently return the English literal.
    ///
    /// `other` is a label the user named themselves; translating it would be
    /// translating their data.
    public var displayName: String {
        switch self {
        case .inbox: String(localized: "Inbox", bundle: .module)
        case .sent: String(localized: "Sent", bundle: .module)
        case .drafts: String(localized: "Drafts", bundle: .module)
        case .junk: String(localized: "Spam", bundle: .module)
        case .trash: String(localized: "Trash", bundle: .module)
        case .archive: String(localized: "Archive", bundle: .module)
        case .snoozed: String(localized: "Snoozed", bundle: .module)
        case .flagged: String(localized: "Starred", bundle: .module)
        case .important: String(localized: "Important", bundle: .module)
        case .all: String(localized: "All mail", bundle: .module)
        case .other(let name): name.capitalized
        }
    }

    /// SF Symbol, chosen to match the vocabulary rather than the plumbing:
    /// these are labels, not folders.
    public var symbolName: String {
        switch self {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .junk: "xmark.bin"
        case .trash: "trash"
        case .archive: "archivebox"
        case .snoozed: "clock"
        case .flagged: "star"
        case .important: "exclamationmark"
        case .all: "envelope"
        case .other: "tag"
        }
    }
}
