import Foundation
import Testing

@testable import PLMailCore

/// Serialisation is the one part of composing nobody can proofread: the sender
/// sees the editor, the recipient sees the HTML, and if those disagree there is
/// no screen anywhere that shows it.
@Suite("Rich text")
struct RichTextTests {
    private func styled(_ text: String, _ style: MailInlineStyle) -> AttributedString {
        var piece = AttributedString(text)
        piece.inlineStyle = style

        return piece
    }

    // MARK: - Writing

    @Test("Plain text becomes one div")
    func plainLine() {
        #expect(MailHTML.html(from: AttributedString("Hello")) == "<div>Hello</div>")
    }

    @Test("Each line becomes its own div, and blank lines survive")
    func lines() {
        let html = MailHTML.html(from: AttributedString("one\n\ntwo"))

        #expect(html == "<div>one</div><div><br></div><div>two</div>")
    }

    /// A blank line at the end is how people leave room above a signature. If
    /// it vanished the signature would jump up against the text.
    @Test("A trailing blank line is kept")
    func trailingBlankLine() {
        #expect(MailHTML.html(from: AttributedString("hi\n")) == "<div>hi</div><div><br></div>")
    }

    @Test(
        "Each style emits the tag that survives the server's sanitiser",
        arguments: [
            (MailInlineStyle.bold, "<strong>x</strong>"),
            (.italic, "<em>x</em>"),
            (.underline, "<u>x</u>"),
            (.strikethrough, "<s>x</s>"),
        ])
    func singleStyles(style: MailInlineStyle, expected: String) {
        #expect(MailHTML.html(from: styled("x", style)) == "<div>\(expected)</div>")
    }

    @Test("Combined styles nest in a fixed order")
    func combinedStyles() {
        let text = styled("x", [.bold, .italic, .underline, .strikethrough])

        #expect(
            MailHTML.html(from: text)
                == "<div><strong><em><u><s>x</s></u></em></strong></div>")
    }

    /// Formatting that spans a line break has to close and reopen, or the
    /// output is not well-formed and every downstream sanitiser guesses
    /// differently about where the bold ends.
    @Test("A style spanning a newline closes on each line")
    func styleAcrossNewline() {
        let text = styled("one\ntwo", .bold)

        #expect(
            MailHTML.html(from: text)
                == "<div><strong>one</strong></div><div><strong>two</strong></div>")
    }

    @Test("Links are emitted outside the style tags")
    func link() {
        var text = styled("plMail", .bold)
        text.link = URL(string: "https://example.com/a?b=1&c=2")

        #expect(
            MailHTML.html(from: text)
                == "<div><a href=\"https://example.com/a?b=1&amp;c=2\"><strong>plMail</strong></a></div>"
        )
    }

    /// The whole point of escaping. Someone writing about `<script>` in a mail
    /// to a colleague is ordinary, and it must arrive as text.
    @Test("Markup in the text is escaped, ampersands first")
    func escaping() {
        let html = MailHTML.html(from: AttributedString("a & b <script> \"q\""))

        #expect(html == "<div>a &amp; b &lt;script&gt; &quot;q&quot;</div>")
    }

    @Test("The plain-text alternative spells out link targets")
    func plainTextAlternative() {
        var text = AttributedString("see ")
        var link = AttributedString("the docs")
        link.link = URL(string: "https://example.com")
        text.append(link)

        #expect(MailHTML.plainText(from: text) == "see the docs <https://example.com>")
    }

    /// A URL that is its own link text would otherwise be printed twice.
    @Test("A bare URL is not repeated in the text alternative")
    func plainTextBareURL() {
        var text = AttributedString("https://example.com")
        text.link = URL(string: "https://example.com")

        #expect(MailHTML.plainText(from: text) == "https://example.com")
    }

    // MARK: - Reading

    @Test("Divs and brs come back as line breaks")
    func parseLines() {
        let text = MailHTML.attributedString(fromHTML: "<div>one</div><div>two<br>three</div>")

        #expect(String(text.characters) == "one\ntwo\nthree")
    }

    @Test(
        "Both spellings of each tag are understood",
        arguments: [
            ("<b>x</b>", MailInlineStyle.bold),
            ("<strong>x</strong>", .bold),
            ("<i>x</i>", .italic),
            ("<em>x</em>", .italic),
            ("<u>x</u>", .underline),
            ("<s>x</s>", .strikethrough),
            ("<strike>x</strike>", .strikethrough),
            ("<del>x</del>", .strikethrough),
        ])
    func parseTags(html: String, expected: MailInlineStyle) {
        let text = MailHTML.attributedString(fromHTML: html)

        #expect(text.runs.first?.inlineStyle == expected)
    }

    @Test("Nested tags combine")
    func parseNested() {
        let text = MailHTML.attributedString(fromHTML: "<strong><em>x</em></strong>")

        #expect(text.runs.first?.inlineStyle == [.bold, .italic])
    }

    /// Real mail contains this. Popping the most recently opened style rather
    /// than the matching one would leave the wrong half of it applied to
    /// everything after.
    @Test("Improperly nested tags close the style they name")
    func parseMisnested() {
        let text = MailHTML.attributedString(fromHTML: "<b><i>x</b>y</i>z")
        let styles = text.runs.map { $0.inlineStyle ?? [] }

        #expect(styles.first == [.bold, .italic])
        #expect(styles.dropFirst().first == [.italic])
        #expect(styles.last == [])
    }

    @Test("Anchors become links")
    func parseLink() {
        let text = MailHTML.attributedString(
            fromHTML: "<a href=\"https://example.com/a?b=1&amp;c=2\">docs</a>")

        #expect(text.runs.first?.link == URL(string: "https://example.com/a?b=1&c=2"))
    }

    @Test("Unknown tags contribute their text and nothing else")
    func parseUnknownTags() {
        let text = MailHTML.attributedString(
            fromHTML: "<span style=\"color:red\"><font size=\"7\">x</font></span>")

        #expect(String(text.characters) == "x")
        #expect(text.runs.first?.inlineStyle == nil)
    }

    @Test(
        "Entities are decoded",
        arguments: [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", "\u{00A0}"),
        ])
    func parseEntities(entity: String, expected: String) {
        let text = MailHTML.attributedString(fromHTML: "<div>\(entity)</div>")

        #expect(String(text.characters) == expected)
    }

    /// Decoding `&amp;` before `&#39;` would turn `&amp;#39;` — which is how
    /// someone writes about an entity — into an apostrophe.
    @Test("A double-escaped entity is decoded exactly once")
    func parseDoubleEscaped() {
        let text = MailHTML.attributedString(fromHTML: "<div>&amp;#39;</div>")

        #expect(String(text.characters) == "&#39;")
    }

    // MARK: - Round trip

    @Test("Formatting survives a trip through HTML and back")
    func roundTrip() {
        var text = AttributedString("plain ")
        text.append(styled("bold", .bold))
        text.append(AttributedString(" and\n"))
        text.append(styled("struck", [.italic, .strikethrough]))

        let restored = MailHTML.attributedString(fromHTML: MailHTML.html(from: text))

        #expect(String(restored.characters) == String(text.characters))
        #expect(
            restored.runs.map { $0.inlineStyle ?? [] } == text.runs.map { $0.inlineStyle ?? [] })
    }

    // MARK: - Quoting

    @Test("A quote wraps the original's own HTML")
    func quoteHTML() {
        let quote = MailHTML.quote(
            author: "Ada", date: nil, html: "<div>original</div>", text: nil)

        #expect(quote.contains("<blockquote"))
        #expect(quote.contains("<div>original</div>"))
        #expect(quote.contains("Ada wrote:"))
    }

    /// A plain-text original still has to arrive as a quote, and its own
    /// angle brackets must not become markup on the way.
    @Test("A plain-text original is escaped into the quote")
    func quotePlainText() {
        let quote = MailHTML.quote(author: "Ada", date: nil, html: nil, text: "a < b\nsecond")

        #expect(quote.contains("<div>a &lt; b</div><div>second</div>"))
    }

    @Test("The quote is split back off a draft body")
    func splitQuote() {
        let split = MailHTML.splitQuote(
            fromHTML: "<div>mine</div><blockquote>theirs</blockquote>")

        #expect(split.body == "<div>mine</div>")
        #expect(split.quote == "<blockquote>theirs</blockquote>")
    }

    @Test("A body with no quote splits into itself")
    func splitNoQuote() {
        let split = MailHTML.splitQuote(fromHTML: "<div>mine</div>")

        #expect(split.body == "<div>mine</div>")
        #expect(split.quote == nil)
    }
}
