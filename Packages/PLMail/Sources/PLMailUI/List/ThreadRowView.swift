#if os(iOS)

public import PLMailCore

import SwiftUI

/// One conversation in a list.
///
/// A single state-driven component, mirroring the web UI's `_thread_row`:
/// every affordance keys off the thread's state rather than there being a
/// read row and an unread row. That is what keeps the two clients looking
/// like the same product as the states multiply.
///
/// Three columns, in the order the eye uses them: who (avatar, scannable
/// without reading), what (sender, subject, snippet), and when plus state.
///
/// Everything that is a fact *about* the conversation rather than its content
/// — the date, an attachment, a star, unread — is gathered into one trailing
/// column instead of being scattered through the text. Scanning a list for
/// "which of these is still unread" then means running the eye down a single
/// narrow strip, rather than looking in a different place on each row.
public struct ThreadRowView: View {
    /// Which account a row arrived in, in a unified feed.
    ///
    /// The colour is seeded on the account's key rather than its display name,
    /// so renaming a mailbox in plMail does not recolour every row it owns.
    public struct AccountTag: Equatable, Sendable {
        let name: String
        let key: String

        public init(name: String, key: String) {
            self.name = name
            self.key = key
        }
    }

    let thread: StoredThread
    /// Shown only in a unified feed, where "which mailbox is this from?"
    /// is a real question. In a single-account list it is noise.
    let account: AccountTag?
    /// Absent in previews and in any list where starring is not offered; the
    /// star then falls back to an indicator.
    var onToggleStar: (() -> Void)?
    var isSelected = false
    /// Drawn by the row rather than through `listRowBackground`, which fills
    /// the whole row rectangle and ignores any inset applied to it — so the
    /// highlight would run to the pane's edge and square off its corner.
    var isOpen = false
    /// Tapping the avatar picks the row out for a bulk action. Absent where
    /// multi-select is not offered, in which case the avatar is inert.
    var onToggleSelection: (() -> Void)?
    /// The matched text from `SearchSnippet/get`, when this row is a search
    /// result and the server offered one. Replaces the generic preview, which
    /// in a ranked search is the same opening line on every row and says
    /// nothing about why the message came back.
    var snippet: String?

    /// At accessibility sizes a row that keeps its columns has no room left
    /// for any of them: the sender truncates to "Ada Lovel…" so that a
    /// timestamp can sit beside it. Stacking is what the system's own lists
    /// do, and it is the difference between a large-text layout that works
    /// and one that merely does not crash.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Grows with the text size, because the date inside it does.
    @ScaledMetric(relativeTo: .caption2) private var statusWidth: CGFloat = 44

    public init(
        thread: StoredThread,
        account: AccountTag? = nil,
        isSelected: Bool = false,
        isOpen: Bool = false,
        snippet: String? = nil,
        onToggleStar: (() -> Void)? = nil,
        onToggleSelection: (() -> Void)? = nil
    ) {
        self.thread = thread
        self.account = account
        self.isSelected = isSelected
        self.isOpen = isOpen
        self.snippet = snippet
        self.onToggleStar = onToggleStar
        self.onToggleSelection = onToggleSelection
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
                // Optically aligned with the first line of text rather than
                // its box: the cap height sits a little below the top of the
                // line.
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                topLine
                subjectLine
                snippetLine
                badges
            }
            // The rule between rows starts where the text does, not at the
            // pane edge — an unbroken line under the avatars would draw a
            // grid, whereas one that begins at the sender reads as the rows
            // being stacked. Set here rather than at the call site so the
            // inset tracks the avatar if its size ever changes.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }

            statusColumn
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background {
            if isOpen || isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(isOpen ? 0.16 : 0.10))
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(thread.isFlagged ? .ui("Unstar") : .ui("Star"))) {
            onToggleStar?()
        }
        .accessibilityAction(named: Text(isSelected ? .ui("Deselect") : .ui("Select"))) {
            onToggleSelection?()
        }
    }

    @ViewBuilder
    private var avatar: some View {
        let circle = SenderAvatar(
            name: thread.participantsSummary,
            address: thread.participantsAddress,
            isSelected: isSelected
        )

        if let onToggleSelection {
            Button(action: onToggleSelection) { circle }
                .buttonStyle(.plain)
                // The circle is 40pt; the tap target has to clear 44.
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .accessibilityHidden(true)
        } else {
            circle
        }
    }

    @ViewBuilder
    private var topLine: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Date on its own line, sender free to wrap. Two lines of a name
            // people can read beats one line of a name they cannot.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    senderName.lineLimit(2)
                    messageCountBadge
                }

            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                senderName.lineLimit(1)
                messageCountBadge

                Spacer(minLength: 4)
            }
        }
    }

    private var senderName: some View {
        Text(participants)
            .font(.subheadline)
            .fontWeight(thread.isUnread ? .semibold : .regular)
            .foregroundStyle(thread.isUnread ? .primary : .secondary)
    }

    /// Bare, not a pill. A capsule around two digits is a badge, and a badge
    /// claims the reply count is worth acting on; it is only ever context for
    /// the sender beside it. Small and muted says that.
    @ViewBuilder
    private var messageCountBadge: some View {
        if thread.messageCount > 1 {
            Text("\(thread.messageCount)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private var subjectLine: some View {
        Text(subject)
            .font(.subheadline)
            .fontWeight(thread.isUnread ? .semibold : .regular)
            .foregroundStyle(.primary)
            // The subject is the one line worth reading in full. At large
            // sizes it gets a second line rather than an ellipsis. The star
            // no longer shares this line, so wrapping costs nothing.
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// When it arrived, and what state it is in — one narrow strip down the
    /// trailing edge.
    ///
    /// A floor on the width rather than a fixed one, so the dates line up with
    /// each other instead of ragging between "09:41" and "12 Mar", and a
    /// starred row is exactly as wide as an unstarred one — while a date that
    /// genuinely needs more room, at an accessibility text size, takes it from
    /// the subject rather than spilling over it.
    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(relativeDate)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            if thread.hasAttachment {
                Image(systemName: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            star

            // Green rather than the tint, so unread is legible as unread and
            // not confused with the accent-coloured highlight the open row
            // already carries.
            if thread.isUnread {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(minWidth: statusWidth, alignment: .trailing)
        .accessibilityHidden(true)
    }

    /// A control when the list can act on it, a plain indicator when it
    /// cannot — never a button that looks tappable and does nothing.
    ///
    /// The unstarred glyph stays drawn, faintly, rather than appearing only
    /// once starred. A star that is invisible until it is on cannot be turned
    /// on, and starring is the one row action worth reaching without a swipe
    /// or a long press.
    @ViewBuilder
    private var star: some View {
        if let onToggleStar {
            Button(action: onToggleStar) {
                starIcon
            }
            .buttonStyle(.plain)
            // The glyph is well under the 44pt minimum on its own. A
            // *minimum* rather than a size: at an accessibility text size
            // the glyph outgrows any fixed box and would draw over the
            // unread dot stacked beneath it.
            .frame(minWidth: 30, minHeight: 22)
            .contentShape(.rect)
            .accessibilityHidden(true)
        } else if thread.isFlagged {
            starIcon
        }
    }

    /// Amber rather than the system orange, which next to muted avatars is the
    /// most saturated thing on screen and pulls the eye off the subject.
    private var starIcon: some View {
        Image(systemName: thread.isFlagged ? "star.fill" : "star")
            .font(.caption2)
            .foregroundStyle(
                thread.isFlagged
                    ? Color(red: 0.80, green: 0.62, blue: 0.20) : Color.secondary.opacity(0.30)
            )
            .contentTransition(.symbolEffect(.replace))
    }

    @ViewBuilder
    private var snippetLine: some View {
        if let snippet {
            Text(highlighted(snippet))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if thread.snippet.isEmpty == false {
            Text(thread.snippet)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The server's snippet as attributed text.
    ///
    /// Built through `SnippetText`, which understands the one tag the server
    /// emits and leaves everything else as the characters the sender typed —
    /// this string is message content, and the whole point is that it cannot
    /// carry markup of its own.
    private func highlighted(_ html: String) -> AttributedString {
        var result = AttributedString()

        for run in SnippetText.runs(from: html) {
            var piece = AttributedString(run.text)

            if run.isHighlighted {
                piece.foregroundColor = .primary
                piece.font = .footnote.weight(.semibold)
            }

            result.append(piece)
        }

        return result
    }

    /// The row's quiet metadata. Kept on its own line so a long subject never
    /// competes with it for width, and omitted entirely when there is none —
    /// an empty line would make every row taller for the sake of a few.
    @ViewBuilder
    private var badges: some View {
        if account != nil || thread.snoozedUntil != nil {
            HStack(spacing: 8) {
                if let snoozedUntil = thread.snoozedUntil {
                    // Tinted rather than grey: a snoozed conversation is not
                    // in the inbox, and a row that looks identical to its
                    // neighbours would be a surprise when it reappears.
                    Label(SnoozeMenu.badge(for: snoozedUntil), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }

                if let account {
                    accountTag(account)
                }
            }
            .padding(.top, 2)
            .accessibilityHidden(true)
        }
    }

    /// Which account this arrived in — a dot and a word, not a badge.
    ///
    /// It was a filled capsule, which made the least important thing on the row
    /// the heaviest: a solid shape outweighs text, and against a muted palette
    /// it was reliably the first thing the eye landed on. The account is context
    /// for the subject, not a claim on it.
    ///
    /// The dot carries the identity and the label merely confirms it, which is
    /// what lets the text drop to tertiary without becoming unreadable — the
    /// same colour repeated down a column is recognisable long before it is
    /// read, and it is the shorthand the web UI and the README already use.
    private func accountTag(_ account: AccountTag) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(AvatarPalette.color(for: account.key))
                .frame(width: 5, height: 5)

            Text(account.name)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: - Presentation

    private var participants: String {
        thread.participantsSummary.isEmpty ? "(unknown sender)" : thread.participantsSummary
    }

    /// The web UI falls back to a translated "(no subject)" rather than
    /// showing an empty row; a blank line reads as a rendering bug.
    private var subject: String {
        guard let subject = thread.subject, subject.isEmpty == false else {
            return "(no subject)"
        }

        return subject
    }

    private var relativeDate: String {
        let date = thread.latestReceivedAt

        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }

        if Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }

        return date.formatted(.dateTime.year().month(.abbreviated))
    }

    /// The visual affordances are colour, weight and icons, none of which
    /// VoiceOver can read, so the state is spelled out here instead.
    private var accessibilityDescription: String {
        var parts: [String] = []

        if isSelected { parts.append("Selected") }
        if thread.isUnread { parts.append("Unread") }
        if thread.isFlagged { parts.append("Starred") }

        parts.append("From \(participants)")
        parts.append(subject)

        if thread.messageCount > 1 { parts.append("\(thread.messageCount) messages") }
        if thread.hasAttachment { parts.append("Has attachment") }
        if let snoozedUntil = thread.snoozedUntil {
            parts.append(
                "Snoozed until "
                    + snoozedUntil.formatted(date: .abbreviated, time: .shortened))
        }
        if let account { parts.append(account.name) }

        parts.append(thread.latestReceivedAt.formatted(date: .abbreviated, time: .shortened))

        return parts.joined(separator: ", ")
    }
}

#endif
