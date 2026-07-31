#if os(iOS)

import PLMailCore
import SwiftUI

/// How the app read the query, shown back to the user.
///
/// Worth surfacing because the parser drops things silently — `is:bogus`
/// and `after:whenever` narrow nothing and search for nothing. Without this
/// the only signal is results that look wrong for no visible reason; with
/// it, the token simply isn't there.
struct SearchTokensView: View {
    let query: ParsedSearchQuery

    var body: some View {
        if tokens.isEmpty == false {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(tokens, id: \.self) { token in
                        Text(token)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Only the structured parts. Free text needs no explaining — it is
    /// what the user typed.
    private var tokens: [String] {
        var tokens: [String] = []

        if let from = query.from, from.isEmpty == false { tokens.append("from: \(from)") }
        if let to = query.to, to.isEmpty == false { tokens.append("to: \(to)") }
        if let subject = query.subject, subject.isEmpty == false {
            tokens.append("subject: \(subject)")
        }
        if query.hasAttachment == true { tokens.append("has attachment") }
        if query.isUnread == true { tokens.append("unread") }
        if query.isRead == true { tokens.append("read") }
        if query.isStarred == true { tokens.append("starred") }
        if let role = query.mailboxRole { tokens.append("in: \(role)") }
        if let after = query.after {
            tokens.append("after \(after.formatted(date: .abbreviated, time: .omitted))")
        }
        if let before = query.before {
            tokens.append("before \(before.formatted(date: .abbreviated, time: .omitted))")
        }

        return tokens
    }
}

#endif
