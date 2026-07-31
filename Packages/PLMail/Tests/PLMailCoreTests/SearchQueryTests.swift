import Foundation
import Testing

@testable import PLMailCore

/// The parser exists to agree with `SearchQueryParser.php`. Every case here is
/// a behaviour of that file, including the ones that look like bugs — a client
/// that "fixes" them makes the same query mean two different things depending
/// on which client you typed it into.
@Suite("Search query parsing")
struct SearchQueryTests {
    // MARK: - Operators

    @Test("the documented operators are recognised")
    func operators() {
        let query = SearchQuery.parse("from:alice to:bob subject:invoice")

        #expect(query.from == "alice")
        #expect(query.to == "bob")
        #expect(query.subject == "invoice")
        #expect(query.freeText.isEmpty)
    }

    @Test("has:attachment sets the flag, in either spelling")
    func hasAttachment() {
        #expect(SearchQuery.parse("has:attachment").hasAttachment == true)
        #expect(SearchQuery.parse("has:attachments").hasAttachment == true)
    }

    @Test("is: sets independent flags")
    func isFlags() {
        #expect(SearchQuery.parse("is:unread").isUnread == true)
        #expect(SearchQuery.parse("is:read").isRead == true)
        #expect(SearchQuery.parse("is:starred").isStarred == true)
    }

    /// Contradictory, and it yields nothing on both clients. Reproduced rather
    /// than resolved: "helpfully" picking one would make the app disagree with
    /// the browser about the same string.
    @Test("is:unread and is:read can both be set")
    func contradictoryFlags() {
        let query = SearchQuery.parse("is:unread is:read")

        #expect(query.isUnread == true)
        #expect(query.isRead == true)
    }

    @Test("in: lowercases its value without validating it")
    func mailboxRole() {
        #expect(SearchQuery.parse("in:INBOX").mailboxRole == "inbox")
        #expect(SearchQuery.parse("in:nonsense").mailboxRole == "nonsense")
    }

    // MARK: - Quirks

    /// The token goes to free text whole, colon included — so this searches for
    /// the literal string rather than erroring or dropping it.
    @Test("an unknown operator becomes free text, colon and all")
    func unknownOperator() {
        let query = SearchQuery.parse("weird:thing")

        #expect(query.freeText == "weird:thing")
    }

    /// Unlike an unknown *operator*, an unknown *value* for a known operator is
    /// dropped entirely. It narrows nothing and it searches for nothing.
    @Test(
        "a bad value for a known operator is dropped, not searched for",
        arguments: ["is:bogus", "has:nonsense", "after:notadate", "before:whenever"]
    )
    func droppedValues(input: String) {
        let query = SearchQuery.parse(input)

        #expect(query.freeText.isEmpty, "\(input) must not leak into free text")
        #expect(query.isEmpty, "\(input) must not set any filter")
    }

    /// Only the first colon splits, so a value may contain colons of its own.
    @Test("a value may contain colons")
    func colonInValue() {
        #expect(SearchQuery.parse("subject:re:re:hello").subject == "re:re:hello")
    }

    @Test("quotes are stripped from an operator's value")
    func quotedValue() {
        #expect(SearchQuery.parse("subject:\"quarterly report\"").subject == "quarterly report")
    }

    /// Quote characters survive into free text on purpose: Postgres reads a
    /// quoted run as a phrase, so stripping them would turn a phrase search
    /// into a bag of words.
    @Test("quotes are kept in free text, where they mean a phrase")
    func quotedFreeText() {
        #expect(SearchQuery.parse("\"quarterly report\"").freeText == "\"quarterly report\"")
    }

    @Test("a quoted run is one token, spaces and all")
    func quotedTokenising() {
        #expect(SearchQuery.tokenize("a \"b c\" d") == ["a", "\"b c\"", "d"])
    }

    /// The more forgiving reading of a half-typed query, and what the server
    /// does.
    @Test("an unterminated quote swallows the rest")
    func unterminatedQuote() {
        #expect(SearchQuery.tokenize("a \"b c") == ["a", "\"b c"])
    }

    @Test("operators and free text mix in any order")
    func mixed() {
        let query = SearchQuery.parse("invoice from:acme has:attachment overdue")

        #expect(query.from == "acme")
        #expect(query.hasAttachment == true)
        #expect(query.freeText == "invoice overdue")
    }

    @Test("an empty query parses to nothing")
    func empty() {
        #expect(SearchQuery.parse("").isEmpty)
        #expect(SearchQuery.parse("   ").isEmpty)
    }

    /// A leading colon has an empty operator name, which is unknown, so the
    /// whole token is free text.
    @Test("a leading colon is free text")
    func leadingColon() {
        #expect(SearchQuery.parse(":hello").freeText == ":hello")
    }

    /// The server sets the field to an empty string here. The compiler skips
    /// empties, which is the same outcome: an empty substring match selects
    /// everything, i.e. narrows nothing.
    @Test("an operator with no value narrows nothing")
    func emptyValue() {
        let query = SearchQuery.parse("from:")

        #expect(query.from == "")
        #expect(SearchQueryCompiler.conditions(for: query, mailboxID: nil).isEmpty)
    }

    // MARK: - Dates

    @Test("dates parse in the documented format")
    func isoDates() throws {
        let query = SearchQuery.parse("after:2024-01-01 before:2024-12-31")

        #expect(query.after != nil)
        #expect(query.before != nil)
        #expect(try #require(query.after) < #require(query.before))
        #expect(query.hasDateBound)
    }

    @Test(
        "the date formats people actually type are accepted",
        arguments: ["2024-01-05", "2024/01/05", "05.01.2024"]
    )
    func dateFormats(input: String) {
        #expect(SearchQuery.parseDate(input) != nil)
    }

    @Test("today and yesterday resolve relative to now")
    func relativeDates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = try #require(SearchQuery.parseDate("today", now: now))
        let yesterday = try #require(SearchQuery.parseDate("yesterday", now: now))

        #expect(today > yesterday)
        #expect(Calendar.current.isDate(today, inSameDayAs: now))
    }
}
