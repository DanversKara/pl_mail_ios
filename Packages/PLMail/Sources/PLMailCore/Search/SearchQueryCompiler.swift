import Foundation
import JMAPKit

/// Turns a parsed query into a JMAP filter, per account.
///
/// Per account because `in:` names a *role*, and a role resolves to a
/// different mailbox id in every account — there is no cross-account mailbox.
/// An account that has no mailbox for the requested role is skipped rather
/// than errored on: a Gmail account has no Archive binding until one exists,
/// and refusing the whole search over that would be absurd.
public enum SearchQueryCompiler {
    /// The conditions a query implies, before they are combined.
    ///
    /// Split out from ``filter(for:mailboxID:)`` so an empty query is
    /// recognisable as "no conditions" rather than as a filter that happens to
    /// match everything.
    ///
    /// - Parameters:
    ///   - query: The parsed search string.
    ///   - mailboxID: The mailbox `in:` resolved to in this account, if any.
    /// - Returns: The conditions, in no particular order.
    public static func conditions(
        for query: ParsedSearchQuery,
        mailboxID: MailboxID?
    ) -> [EmailFilter] {
        var conditions: [EmailFilter] = []

        // Empty values are skipped: `from:` with nothing after it sets an empty
        // string server-side, which matches everything, which is the same as
        // not filtering at all.
        if let from = query.from, from.isEmpty == false { conditions.append(.from(from)) }
        if let to = query.to, to.isEmpty == false { conditions.append(.to(to)) }
        if let subject = query.subject, subject.isEmpty == false {
            conditions.append(.subject(subject))
        }

        if query.hasAttachment == true { conditions.append(.hasAttachment(true)) }

        // Backed by the `seen_at` column, exposed as the `$seen` keyword. Both
        // flags set is contradictory and returns nothing — reproduced rather
        // than resolved, so the two clients agree.
        if query.isUnread == true { conditions.append(.notKeyword(.seen)) }
        if query.isRead == true { conditions.append(.hasKeyword(.seen)) }
        if query.isStarred == true { conditions.append(.hasKeyword(.flagged)) }

        if let mailboxID { conditions.append(.inMailbox(mailboxID)) }

        // `after` is inclusive and `before` is strict, matching the compiler.
        if let after = query.after { conditions.append(.after(UTCDate(after))) }
        if let before = query.before { conditions.append(.before(UTCDate(before))) }

        if query.freeText.isEmpty == false {
            // Real full-text search: a Postgres tsvector matched with
            // websearch_to_tsquery, so this is stemmed and ranked rather than
            // a substring scan — and quoted runs are phrases.
            conditions.append(.text(query.freeText))
        }

        return conditions
    }

    /// The filter for one account, or nil when the query selects nothing here.
    public static func filter(
        for query: ParsedSearchQuery,
        mailboxID: MailboxID?
    ) -> EmailFilter? {
        let conditions = conditions(for: query, mailboxID: mailboxID)

        guard conditions.isEmpty == false else { return nil }
        guard conditions.count > 1 else { return conditions[0] }

        return .and(conditions)
    }

    /// Whether this account can serve the query at all.
    ///
    /// A query naming `in:archive` means nothing in an account with no Archive
    /// binding, and including it would return that account's whole mailbox.
    public static func canSearch(
        _ query: ParsedSearchQuery,
        mailboxes: [MailboxSnapshot]
    ) -> Bool {
        guard let role = query.mailboxRole else { return true }

        return mailboxes.contains { $0.role?.rawValue == role }
    }

    /// The mailbox `in:` names within one account.
    public static func mailboxID(
        for query: ParsedSearchQuery,
        mailboxes: [MailboxSnapshot]
    ) -> MailboxID? {
        guard let role = query.mailboxRole else { return nil }

        return mailboxes.first { $0.role?.rawValue == role }?.mailboxID
    }
}

extension FeedID {
    /// A feed for one search.
    ///
    /// Keyed on the query text so two different searches cannot share rows,
    /// and so returning to the same search shows its results immediately.
    public static func search(_ raw: String) -> FeedID {
        .searchResults(query: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
