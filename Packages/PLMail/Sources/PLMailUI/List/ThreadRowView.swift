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
    /// Where the keyboard is, which on a collapsed layout is not the same as
    /// what is open.
    ///
    /// A **stroke**, never a third fill opacity. Open is accent at 0.16 and
    /// ticked is accent at 0.10; a third value between them would be three
    /// states nobody can tell apart at a glance, which is the whole job the
    /// highlight has.
    var isFocused = false
    /// Tapping the avatar picks the row out for a bulk action. Absent where
    /// multi-select is not offered, in which case the avatar is inert.
    var onToggleSelection: (() -> Void)?
    /// The matched text from `SearchSnippet/get`, when this row is a search
    /// result and the server offered one. Replaces the generic preview, which
    /// in a ranked search is the same opening line on every row and says
    /// nothing about why the message came back.
    ///
    /// **Both halves, not one string.** A subject match drawn into the body
    /// slot repeats the same words twice on one row and leaves the subject
    /// line — where the eye actually looks — unmarked, so the row never says
    /// why it came back.
    var highlight: SearchHighlight?
    /// The custom labels on this conversation, resolved by the list.
    ///
    /// Passed in rather than looked up: a row that asked the store for its own
    /// labels would put a store read inside a scrolling `ForEach`, once per row
    /// per redraw, on a device that is often on battery.
    var labels: [LabelChipModel] = []
    /// The width of the **list column**, measured — not the size class.
    ///
    /// On iPad the list pane is 396–540pt, so a size-class test answers the
    /// same at both ends of that range and would therefore decide nothing. Zero
    /// until the column has been measured, which buys the narrow budget for one
    /// frame rather than briefly overflowing a column nobody has sized yet.
    var paneWidth: CGFloat = 0
    /// Whether to shout "New" on this row.
    ///
    /// **Passed in, never read from `thread.isNew`.** Drawing the row is what
    /// spends the marker: the display is reported, the column is cleared, and
    /// `@Query` republishes — so a badge bound to the column would appear and
    /// vanish inside a second while somebody was looking at it. The list holds
    /// the set in memory for as long as it is on screen instead. See
    /// ``ThreadListView``.
    var isNew = false

    /// At accessibility sizes a row that keeps its columns has no room left
    /// for any of them: the sender truncates to "Ada Lovel…" so that a
    /// timestamp can sit beside it. Stacking is what the system's own lists
    /// do, and it is the difference between a large-text layout that works
    /// and one that merely does not crash.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The list's own density knobs — preview lines, avatars, unread weight —
    /// all of which the server sets and none of which reached this row before.
    /// An unpopulated environment is ``ResolvedTheme/placeholder``, whose
    /// values are exactly what the row drew when they were literals.
    @Environment(\.theme) private var theme

    /// Grows with the text size, because the date inside it does.
    @ScaledMetric(relativeTo: .caption2) private var statusWidth: CGFloat = 44

    public init(
        thread: StoredThread,
        account: AccountTag? = nil,
        isSelected: Bool = false,
        isOpen: Bool = false,
        isFocused: Bool = false,
        highlight: SearchHighlight? = nil,
        labels: [LabelChipModel] = [],
        paneWidth: CGFloat = 0,
        isNew: Bool = false,
        onToggleStar: (() -> Void)? = nil,
        onToggleSelection: (() -> Void)? = nil
    ) {
        self.thread = thread
        self.account = account
        self.isSelected = isSelected
        self.isOpen = isOpen
        self.isFocused = isFocused
        self.highlight = highlight
        self.labels = labels
        self.paneWidth = paneWidth
        self.isNew = isNew
        self.onToggleStar = onToggleStar
        self.onToggleSelection = onToggleSelection
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Dropped entirely rather than drawn blank when the theme turns
            // avatars off: a 40pt hole where the circle was is a bug, and the
            // text should take the width back.
            if theme.showsAvatars {
                avatar
                    // Optically aligned with the first line of text rather
                    // than its box: the cap height sits a little below the top
                    // of the line.
                    .padding(.top, 2)
            }

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
                    .fill(ThemeAccent().opacity(isOpen ? 0.16 : 0.10))
            }
        }
        // Over the fill, not instead of it: on a wide layout the cursor and
        // the open message are the same row, and a stroke that replaced the
        // fill would make moving the keyboard look like closing the message.
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(ThemeAccent(), lineWidth: 2)
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

                // Below the name at accessibility sizes rather than beside it.
                // A capsule sharing the line with a two-line wrapped name at
                // 53pt text leaves the name about four characters, which is
                // the truncation this row's whole layout exists to avoid.
                newBadge
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                senderName.lineLimit(1)
                messageCountBadge
                newBadge

                Spacer(minLength: 4)
            }
        }
    }

    /// "New" — never displayed to this user before, and arrived in the last
    /// day.
    ///
    /// On the top line, where the eye starts, because that is the whole claim
    /// it makes: this is mail you have not seen on any device. It is
    /// deliberately not the unread dot in the trailing column — new and unread
    /// are different facts and are allowed to disagree, and a conversation read
    /// on a laptop this morning is still new to a phone that has never drawn
    /// its row.
    ///
    /// Accent-tinted rather than red: it is a fact about the row, not a warning
    /// about it, and red beside the amber star and the green unread dot would
    /// make three saturated colours competing on one row.
    @ViewBuilder
    private var newBadge: some View {
        if isNew {
            Text(.ui("New"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(ThemeAccent().opacity(0.16), in: Capsule())
                .fixedSize()
        }
    }

    private var senderName: some View {
        Text(participants)
            .font(.subheadline)
            .fontWeight(theme.unreadEmphasis.weight(isUnread: thread.isUnread))
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

    /// The subject, with the search's own marked-up version preferred.
    ///
    /// Drawn here rather than in the preview slot below: the server marks the
    /// subject when the subject is what matched, and putting that string under
    /// the subject line shows the same words twice while leaving the line the
    /// eye actually reads unmarked.
    private var subjectLine: some View {
        Text(subjectText)
            .font(.subheadline)
            .fontWeight(theme.unreadEmphasis.weight(isUnread: thread.isUnread))
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

    /// The subject as it should be drawn, marked up when the search says the
    /// subject matched. Separate from ``subject`` so the plain string stays
    /// available for the accessibility sentence, which must not carry the
    /// server's markup.
    private var subjectText: AttributedString {
        guard let marked = highlight?.subject else { return AttributedString(subject) }

        return highlighted(marked, in: .subheadline)
    }

    /// The preview, at whatever depth the theme asks for.
    ///
    /// **Zero lines means no view at all, not a `lineLimit(0)`.** SwiftUI reads
    /// zero as "no limit", so the naive spelling of "turn the preview off"
    /// gives an unlimited preview — a five-paragraph message drawn in full in
    /// a list row.
    @ViewBuilder
    private var snippetLine: some View {
        if theme.previewLines > 0 {
            // Only the body half reaches this slot. A subject match belongs on
            // the subject line, and a row with neither falls back to its own
            // stored preview, which is honest rather than blank.
            if let snippet = highlight?.body {
                Text(highlighted(snippet, in: .footnote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(theme.previewLines)
            } else if thread.snippet.isEmpty == false {
                Text(thread.snippet)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(theme.previewLines)
            }
        }
    }

    /// The server's snippet as attributed text.
    ///
    /// Built through `SnippetText`, which understands the one tag the server
    /// emits and leaves everything else as the characters the sender typed —
    /// this string is message content, and the whole point is that it cannot
    /// carry markup of its own.
    ///
    /// `font` is the line's own font, so a marked run can be made heavier
    /// without also being resized: passing the wrong one shows as a subject
    /// whose matched words are footnote-sized.
    private func highlighted(_ html: String, in font: Font) -> AttributedString {
        var result = AttributedString()

        for run in SnippetText.runs(from: html) {
            var piece = AttributedString(run.text)

            if run.isHighlighted {
                piece.foregroundColor = .primary
                piece.font = font.weight(.semibold)
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
        if account != nil || thread.snoozedUntil != nil || labels.isEmpty == false {
            HStack(spacing: 8) {
                // First on the line, because a label is the one thing here the
                // user put there themselves. The cluster draws nothing at all
                // when there are no labels, so it costs a row without them
                // neither height nor spacing.
                LabelChipCluster(labels, paneWidth: paneWidth)

                if let snoozedUntil = thread.snoozedUntil {
                    // Tinted rather than grey: a snoozed conversation is not
                    // in the inbox, and a row that looks identical to its
                    // neighbours would be a surprise when it reappears.
                    Label(SnoozeMenu.badge(for: snoozedUntil), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.themeAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(ThemeAccent().opacity(0.12), in: Capsule())
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
        // Before "Unread", and said even when the row is also unread: the
        // capsule is the first thing a sighted reader sees, and the two are
        // different claims rather than one restated.
        if isNew { parts.append("New") }
        if thread.isUnread { parts.append("Unread") }
        if thread.isFlagged { parts.append("Starred") }

        parts.append("From \(participants)")
        parts.append(subject)

        // Spoken in full, and every one of them — the badge row is
        // `.accessibilityHidden`, and the cluster on screen shows at most two
        // chips plus a count. Colour alone carries nothing here, and "+2" read
        // aloud names nothing at all.
        //
        // The spoken path rather than the leaf, so two labels called `Q1` under
        // different parents are told apart by ear as well as by eye.
        for label in labels { parts.append(label.path) }

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
