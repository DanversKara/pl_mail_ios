import Foundation
import JMAPKit

/// A search string, parsed.
///
/// Mirrors `App\Domain\DTO\ParsedSearchQuery` field for field, because the two
/// clients have to agree about what a query means. Someone who searches
/// `from:acme is:unread` in the browser and then on their phone is entitled to
/// the same results.
public struct ParsedSearchQuery: Hashable, Sendable {
    public var from: String?
    public var to: String?
    public var subject: String?
    public var hasAttachment: Bool?
    public var isUnread: Bool?
    public var isRead: Bool?
    public var isStarred: Bool?
    public var mailboxRole: String?
    public var after: Date?
    public var before: Date?

    /// Everything that was not an operator, joined with spaces.
    ///
    /// Quote characters survive tokenising deliberately: this string is handed
    /// to Postgres's `websearch_to_tsquery`, where a quoted run means a phrase
    /// search. Stripping them would quietly turn a phrase into a bag of words.
    public var freeText: String = ""

    public init() {}

    /// Whether anything was actually asked for.
    public var isEmpty: Bool {
        self == ParsedSearchQuery()
    }

    /// Whether the query narrowed by date.
    ///
    /// Worth knowing for the empty state: mail older than an account's sync
    /// window is not in the database at all, so "no results" for a dated query
    /// usually means the window, not the mail.
    public var hasDateBound: Bool {
        after != nil || before != nil
    }
}

/// Parses a Gmail-style search string.
///
/// A deliberate reimplementation of `SearchQueryParser.php`, including the
/// parts that look like bugs, because matching the server is the whole point.
/// The behaviours worth naming, since each one is a decision:
///
/// - **Quote characters are kept inside tokens.** They are only stripped from
///   an operator's *value*.
/// - **A token splits on its first colon**, so `subject:a:b` searches for
///   `a:b`.
/// - **An unknown operator falls through as free text, colon and all** —
///   `weird:thing` searches for the literal `weird:thing` rather than erroring.
/// - **A bad value for `has:`, `is:`, `after:` or `before:` is dropped
///   silently**, not turned into free text. `is:bogus` narrows nothing and
///   searches for nothing.
/// - **`is:unread` and `is:read` are independent flags.** Setting both is
///   contradictory and yields nothing, on both clients.
public enum SearchQuery {
    public static func parse(_ raw: String) -> ParsedSearchQuery {
        var query = ParsedSearchQuery()
        var remainder: [String] = []

        for token in tokenize(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            guard token.contains(":") else {
                remainder.append(token)
                continue
            }

            // First colon only, so a value may itself contain colons.
            let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(parts.count > 1 ? parts[1] : "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            switch name {
            case "from": query.from = value
            case "to": query.to = value
            case "subject": query.subject = value
            case "has": applyHas(value, to: &query)
            case "is": applyIs(value, to: &query)
            case "in": query.mailboxRole = value.lowercased()
            case "after": query.after = parseDate(value)
            case "before": query.before = parseDate(value)
            default:
                // The whole original token, colon included.
                remainder.append(token)
            }
        }

        query.freeText = remainder.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        return query
    }

    /// Splits on spaces, keeping quoted runs together.
    ///
    /// The quote characters stay in the token — see ``ParsedSearchQuery/freeText``.
    /// An unterminated quote swallows the rest of the string, which is what the
    /// server does and is the more forgiving reading of a half-typed query.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false

        for character in input {
            if character == "\"" {
                inQuote.toggle()
                current.append(character)
                continue
            }

            if character == " ", inQuote == false {
                if current.isEmpty == false {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if current.isEmpty == false {
            tokens.append(current)
        }

        return tokens
    }

    private static func applyHas(_ value: String, to query: inout ParsedSearchQuery) {
        switch value.lowercased() {
        case "attachment", "attachments": query.hasAttachment = true
        default: break  // Dropped, not treated as text.
        }
    }

    private static func applyIs(_ value: String, to query: inout ParsedSearchQuery) {
        switch value.lowercased() {
        case "unread": query.isUnread = true
        case "read": query.isRead = true
        case "starred": query.isStarred = true
        default: break
        }
    }

    /// Parses a date the way a person would write one.
    ///
    /// The server uses PHP's `DateTimeImmutable`, which accepts an enormous
    /// range including relative phrases. This covers the formats the docs
    /// actually promise plus the two relative words people reach for; anything
    /// else is dropped, exactly as an unparseable date is dropped there.
    ///
    /// The divergence is visible rather than silent: the search field shows the
    /// operators it understood, so a date it could not read simply does not
    /// appear as a token.
    ///
    /// Dates are anchored at **local** midnight, because a typed date means
    /// that day where the person is. The server parses in *its own* timezone,
    /// which can differ by an offset — but that is ambiguous there too: the
    /// same query from the same person means different things depending on
    /// where their server thinks it is.
    static func parseDate(_ value: String, now: Date = .now) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        guard trimmed.isEmpty == false else { return nil }

        let calendar = Calendar.current

        switch trimmed.lowercased() {
        case "today": return calendar.startOfDay(for: now)
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        default: break
        }

        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "dd.MM.yyyy", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format

            if let date = formatter.date(from: trimmed) { return date }
        }

        return try? Date(trimmed, strategy: .iso8601)
    }
}
