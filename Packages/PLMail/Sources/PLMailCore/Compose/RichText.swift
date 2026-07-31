import Foundation

/// Bold, italic, underline, strikethrough — as one attribute rather than four.
///
/// **Why a custom attribute at all.** The iOS 26 rich `TextEditor` records
/// bold and italic in `SwiftUI.Font`, which has no public way to ask "is this
/// bold" — it can only be compared against a font you built yourself. Reading
/// formatting straight off the editor's own attributes would therefore mean
/// guessing, so the editor normalises into this instead, and everything
/// downstream — serialisation, the outbox, the tests — reads one introspectable
/// value.
///
/// It also keeps this file free of SwiftUI, which is what lets the HTML
/// serialiser be tested without a simulator.
public struct MailInlineStyle: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let bold = MailInlineStyle(rawValue: 1 << 0)
    public static let italic = MailInlineStyle(rawValue: 1 << 1)
    public static let underline = MailInlineStyle(rawValue: 1 << 2)
    public static let strikethrough = MailInlineStyle(rawValue: 1 << 3)
}

public enum MailInlineStyleAttribute: CodableAttributedStringKey {
    public typealias Value = MailInlineStyle
    public static let name = "de.plmail.inlineStyle"
}

extension AttributeScopes {
    /// Deliberately just the one attribute.
    ///
    /// `link` is Foundation's own and is already reachable on every run;
    /// declaring it here as well makes `run.link` ambiguous between two
    /// identical spellings, which is a confusing compile error a long way from
    /// its cause.
    public struct MailAttributes: AttributeScope {
        public let inlineStyle: MailInlineStyleAttribute
    }

    public var mail: MailAttributes.Type { MailAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.MailAttributes, T>
    ) -> T {
        self[T.self]
    }
}

/// Turning what someone typed into what goes on the wire, and back.
///
/// The target is not "HTML" but the subset plMail's sanitiser keeps: it runs
/// `allowSafeElements()` and strips `class` and `id` outright, so anything
/// clever here would be deleted server-side and the sender would never know.
/// Emitting only what survives means what you see is what arrives.
public enum MailHTML {
    // MARK: - Writing

    /// Serialises the editor's contents.
    ///
    /// Lines become `<div>`s rather than `<p>`s, which is what Gmail, Apple
    /// Mail and plMail's own web composer all emit — `<p>` carries margins that
    /// every mail client renders differently, and a blank line that grows to a
    /// full paragraph gap on the recipient's screen looks like a mistake.
    public static func html(from text: AttributedString) -> String {
        var lines: [String] = []
        var current = ""

        for run in text.runs {
            let style = run.inlineStyle ?? []
            let link = run.link
            let pieces = String(text[run.range].characters).components(separatedBy: "\n")

            for (index, piece) in pieces.enumerated() {
                // Every separator after the first closes the line being built.
                if index > 0 {
                    lines.append(current)
                    current = ""
                }

                current += wrap(escape(piece), style: style, link: link)
            }
        }

        lines.append(current)

        return
            lines
            .map { $0.isEmpty ? "<div><br></div>" : "<div>\($0)</div>" }
            .joined()
    }

    /// The plain-text alternative.
    ///
    /// plMail derives its own plain text from the HTML, so this is for the
    /// benefit of everything else that might read the draft — other JMAP
    /// clients, and recipients whose mail reader prefers text. Link targets are
    /// spelled out, because a bare word that was a link in the HTML part is
    /// information the text part would otherwise lose entirely.
    public static func plainText(from text: AttributedString) -> String {
        var output = ""

        for run in text.runs {
            let slice = String(text[run.range].characters)

            output += slice

            if let link = run.link,
                slice.trimmingCharacters(in: .whitespaces) != link.absoluteString
            {
                output += " <\(link.absoluteString)>"
            }
        }

        return output
    }

    /// Wraps one escaped fragment in its tags.
    ///
    /// Fixed nesting order so the output is stable and diffable, and so the
    /// tests can assert on a string rather than on a tree.
    private static func wrap(_ escaped: String, style: MailInlineStyle, link: URL?) -> String {
        guard escaped.isEmpty == false else { return "" }

        var html = escaped

        if style.contains(.strikethrough) { html = "<s>\(html)</s>" }
        if style.contains(.underline) { html = "<u>\(html)</u>" }
        if style.contains(.italic) { html = "<em>\(html)</em>" }
        if style.contains(.bold) { html = "<strong>\(html)</strong>" }

        if let link {
            html = "<a href=\"\(escape(link.absoluteString))\">\(html)</a>"
        }

        return html
    }

    /// `&` first, or the escapes escape each other.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Reading

    /// Parses the subset back, for a draft being continued.
    ///
    /// Tolerant by design: this reads drafts written by the web composer, and
    /// possibly by some other client, not only its own output. Anything it does
    /// not recognise contributes its text and loses its formatting, which is
    /// the failure everyone can live with — the alternative, refusing to open
    /// the draft, is not.
    public static func attributedString(fromHTML html: String) -> AttributedString {
        var parser = Parser(html: html)

        return parser.run()
    }

    /// Separates a trailing quoted original from the part someone wrote.
    ///
    /// Reply quotes are kept out of the editor entirely — see
    /// ``ComposeModel/quotedHTML`` — so continuing a draft has to put the quote
    /// back where it came from rather than parsing a stranger's newsletter into
    /// an editable rich-text buffer and mangling it.
    public static func splitQuote(fromHTML html: String) -> (body: String, quote: String?) {
        guard let range = html.range(of: "<blockquote", options: .caseInsensitive) else {
            return (html, nil)
        }

        return (String(html[html.startIndex..<range.lowerBound]), String(html[range.lowerBound...]))
    }

    /// Splits a received message into what was written and the history under
    /// it, so a reply five deep does not open as five screens of scrollback.
    ///
    /// Deliberately conservative. Getting this wrong hides something somebody
    /// wrote, which is far worse than showing a quote they could have skipped,
    /// so it only trims on markers that actually mean "quoted", and only when
    /// there is something left to show.
    ///
    /// `class` is not among the signals, though every mail client marks quotes
    /// with one — `gmail_quote` and friends. plMail's sanitiser strips `class`
    /// and `id` outright, so by the time a message reaches this app those are
    /// gone. What survives is `<blockquote>`, the attribution line above it,
    /// and the plain-text separators older clients emit.
    public static func trimQuotedHistory(_ html: String) -> (visible: String, quoted: String?) {
        guard let cut = quoteStart(in: html) else { return (html, nil) }

        let visible = String(html[html.startIndex..<cut])
        let quoted = String(html[cut...])

        // A forward is almost entirely quote. Hiding all of it would leave an
        // empty message and a button, which reads as a bug.
        guard textLength(of: visible) >= 8 else { return (html, nil) }

        return (visible, quoted)
    }

    /// Where the history begins, including the "On … wrote:" line that
    /// introduces it — Gmail hides the attribution with the quote, and leaving
    /// it behind strands a sentence pointing at nothing.
    private static func quoteStart(in html: String) -> String.Index? {
        var candidates: [String.Index] = []

        if let blockquote = html.range(of: "<blockquote", options: .caseInsensitive) {
            var start = blockquote.lowerBound

            if let attribution = attributionStart(in: html, before: start) {
                start = attribution
            }

            candidates.append(start)
        }

        // What clients emitted before blockquote was universal. Matched on the
        // text, then backed up to the block that contains it — cutting at the
        // text itself leaves the opening `<div>` stranded above the fold.
        for marker in ["-----Original Message-----", "-------- Forwarded Message --------"] {
            if let found = html.range(of: marker, options: .caseInsensitive) {
                candidates.append(blockStart(in: html, containing: found.lowerBound))
            }
        }

        return candidates.min()
    }

    /// Finds the start of the block holding the attribution line, searching
    /// only the short stretch just above the quote.
    private static func attributionStart(
        in html: String, before index: String.Index
    ) -> String.Index? {
        let head = html[html.startIndex..<index]

        // The last block that opens before the quote. Anything earlier is the
        // message proper.
        guard let open = head.range(of: "<div", options: [.caseInsensitive, .backwards])
        else { return nil }

        let candidate = String(head[open.lowerBound...])

        guard candidate.count < 400 else { return nil }

        // Must actually look like an attribution: a short line that ends in a
        // colon and names the act of writing. Testing for "wrote:" alone is not
        // enough — German puts the name after the verb ("Am 3. März schrieb
        // Ada:"), so the colon and the verb are in different places.
        let text = stripTags(candidate).trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.hasSuffix(":") else { return nil }

        let verbs = ["wrote", "schrieb", "a écrit", "escribió", "ha scritto"]

        guard verbs.contains(where: { text.lowercased().contains($0) }) else { return nil }

        return open.lowerBound
    }

    /// Backs up to the opening tag of the block a position sits inside.
    private static func blockStart(in html: String, containing index: String.Index) -> String.Index
    {
        let head = html[html.startIndex..<index]

        let opens = ["<div", "<p", "<hr", "<blockquote"]
            .compactMap { head.range(of: $0, options: [.caseInsensitive, .backwards])?.lowerBound }

        return opens.max() ?? index
    }

    private static func stripTags(_ html: String) -> String {
        var output = ""
        var depth = 0

        for character in html {
            if character == "<" {
                depth += 1
            } else if character == ">" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                output.append(character)
            }
        }

        return output
    }

    /// Rough text length, ignoring tags — enough to tell "there is a message
    /// here" from "this is only a quote".
    private static func textLength(of html: String) -> Int {
        var depth = 0
        var count = 0

        for character in html {
            if character == "<" {
                depth += 1
            } else if character == ">" {
                depth = max(0, depth - 1)
            } else if depth == 0, character.isWhitespace == false {
                count += 1
            }
        }

        return count
    }

    /// A quoted original, in the shape every mail client renders as a quote.
    ///
    /// The attribution line matches what the web UI writes, so a thread replied
    /// to from both clients reads consistently.
    public static func quote(
        author: String, date: Date?, html: String?, text: String?
    ) -> String {
        let when = date?.formatted(date: .long, time: .shortened) ?? ""
        let header = escape("On \(when), \(author) wrote:")

        let quoted =
            html
            ?? text.map { plain in
                plain
                    .components(separatedBy: "\n")
                    .map { "<div>\(escape($0))</div>" }
                    .joined()
            }
            ?? ""

        return
            "<div>\(header)</div><blockquote style=\"margin:0 0 0 0.8ex;border-left:2px solid #ccc;padding-left:1ex\">\(quoted)</blockquote>"
    }

    /// A hand-written scanner rather than a real HTML parser.
    ///
    /// The input is already sanitised — plMail stores `bodyHtmlSafe` — so the
    /// hostile cases this would otherwise have to survive have been removed
    /// upstream. What is left is tag soup, which this handles by ignoring
    /// everything it does not know.
    private struct Parser {
        private let characters: [Character]
        private var index = 0
        private var styles: [MailInlineStyle] = []
        private var links: [URL] = []
        private var output = AttributedString()

        init(html: String) {
            characters = Array(html)
        }

        mutating func run() -> AttributedString {
            var text = ""

            while index < characters.count {
                if characters[index] == "<" {
                    append(text)
                    text = ""
                    readTag()
                } else {
                    text.append(characters[index])
                    index += 1
                }
            }

            append(text)

            return trimmingTrailingNewlines(output)
        }

        private mutating func append(_ raw: String) {
            guard raw.isEmpty == false else { return }

            var piece = AttributedString(decodeEntities(raw))
            let style = styles.reduce(into: MailInlineStyle()) { $0.formUnion($1) }

            if style.isEmpty == false { piece.inlineStyle = style }
            if let link = links.last { piece.link = link }

            output.append(piece)
        }

        private mutating func readTag() {
            index += 1  // the "<"

            var tag = ""

            while index < characters.count, characters[index] != ">" {
                tag.append(characters[index])
                index += 1
            }

            if index < characters.count { index += 1 }  // the ">"

            apply(tag: tag)
        }

        private mutating func apply(tag: String) {
            let isClosing = tag.hasPrefix("/")
            let body = isClosing ? String(tag.dropFirst()) : tag
            let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()

            switch name {
            case "br":
                output.append(AttributedString("\n"))

            case "div", "p", "blockquote", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6":
                // Only on the way out, and only once: an opening tag that also
                // broke the line would double every paragraph gap.
                if isClosing { output.append(AttributedString("\n")) }

            case "b", "strong":
                push(.bold, closing: isClosing)

            case "i", "em":
                push(.italic, closing: isClosing)

            case "u":
                push(.underline, closing: isClosing)

            case "s", "strike", "del":
                push(.strikethrough, closing: isClosing)

            case "a":
                if isClosing {
                    if links.isEmpty == false { links.removeLast() }
                } else if let href = attribute("href", in: body), let url = URL(string: href) {
                    links.append(url)
                }

            default:
                break
            }
        }

        private mutating func push(_ style: MailInlineStyle, closing: Bool) {
            if closing {
                // By value, not by position: `<b><i>x</b></i>` is malformed and
                // real, and popping blindly would strip the wrong one.
                if let last = styles.lastIndex(of: style) { styles.remove(at: last) }
            } else {
                styles.append(style)
            }
        }

        /// Only ever asked for `href`, and only on `<a>`.
        private func attribute(_ name: String, in tag: String) -> String? {
            let lowered = tag.lowercased()

            guard let key = lowered.range(of: "\(name)=") else { return nil }

            var rest = tag[key.upperBound...]

            guard let quote = rest.first, quote == "\"" || quote == "'" else {
                // Unquoted: runs to the next space.
                return String(rest.prefix { $0 != " " && $0 != ">" })
            }

            rest = rest.dropFirst()

            return decodeEntities(String(rest.prefix { $0 != quote }))
        }

        private func decodeEntities(_ text: String) -> String {
            guard text.contains("&") else { return text }

            var decoded = text

            // Numeric first, so a literal "&amp;#39;" survives as "&#39;"
            // rather than being decoded twice into an apostrophe.
            decoded = decodeNumericEntities(decoded)

            for (entity, replacement) in [
                ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                ("&apos;", "'"), ("&nbsp;", "\u{00A0}"),
            ] {
                decoded = decoded.replacingOccurrences(of: entity, with: replacement)
            }

            // Ampersand last, for the same reason it is escaped first.
            return decoded.replacingOccurrences(of: "&amp;", with: "&")
        }

        private func decodeNumericEntities(_ text: String) -> String {
            var output = ""
            var rest = Substring(text)

            while let start = rest.range(of: "&#") {
                output += rest[rest.startIndex..<start.lowerBound]

                let after = rest[start.upperBound...]
                let isHex = after.first == "x" || after.first == "X"
                let digits =
                    isHex ? after.dropFirst().prefix(\.isHexDigit) : after.prefix(\.isNumber)
                let remainder = after[digits.endIndex...]

                if digits.isEmpty == false,
                    let value = UInt32(digits, radix: isHex ? 16 : 10),
                    let scalar = Unicode.Scalar(value)
                {
                    output.append(Character(scalar))
                    // The trailing semicolon is optional in the wild.
                    rest = remainder.first == ";" ? remainder.dropFirst() : remainder
                } else {
                    output += "&#"
                    rest = after
                }
            }

            return output + rest
        }

        private func trimmingTrailingNewlines(_ text: AttributedString) -> AttributedString {
            var text = text

            while let last = text.characters.last, last == "\n" {
                text.removeSubrange(text.index(beforeCharacter: text.endIndex)..<text.endIndex)
            }

            return text
        }
    }
}

extension Substring {
    fileprivate func prefix(_ predicate: (Character) -> Bool) -> Substring {
        self.prefix(while: predicate)
    }

    fileprivate func prefix(_ keyPath: KeyPath<Character, Bool>) -> Substring {
        prefix { $0[keyPath: keyPath] }
    }
}

extension AttributedString {
    fileprivate func index(beforeCharacter index: AttributedString.Index) -> AttributedString.Index
    {
        characters.index(before: index)
    }
}
