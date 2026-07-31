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
/// The star sits on the right as a real control rather than a read-only
/// indicator, so the most common one-handed action needs no swipe.
public struct ThreadRowView: View {
    let thread: StoredThread
    /// Shown only in a unified feed, where "which mailbox is this from?"
    /// is a real question. In a single-account list it is noise.
    let accountLabel: String?
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

    public init(
        thread: StoredThread,
        accountLabel: String? = nil,
        isSelected: Bool = false,
        isOpen: Bool = false,
        snippet: String? = nil,
        onToggleStar: (() -> Void)? = nil,
        onToggleSelection: (() -> Void)? = nil
    ) {
        self.thread = thread
        self.accountLabel = accountLabel
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
        }
        // Roomier than a separator-divided list needs to be: without rules
        // between rows, whitespace is the only thing grouping each block.
        .padding(.vertical, 9)
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
            isUnread: thread.isUnread,
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

                dateText
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                senderName.lineLimit(1)
                messageCountBadge

                Spacer(minLength: 4)

                dateText
            }
        }
    }

    private var senderName: some View {
        Text(participants)
            .font(.subheadline)
            .fontWeight(thread.isUnread ? .semibold : .regular)
            .foregroundStyle(thread.isUnread ? .primary : .secondary)
    }

    @ViewBuilder
    private var messageCountBadge: some View {
        if thread.messageCount > 1 {
            Text("\(thread.messageCount)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }

    private var dateText: some View {
        Text(relativeDate)
            .font(.caption)
            .fontWeight(thread.isUnread ? .medium : .regular)
            .foregroundStyle(thread.isUnread ? Color.accentColor : .secondary)
            // Already in the row's combined label, in a form that reads
            // properly out loud ("2 hours ago" rather than "2h").
            .accessibilityHidden(true)
    }

    private var subjectLine: some View {
        // Top-aligned rather than baseline-aligned once the subject can wrap:
        // a star sitting on the baseline of a two-line subject floats in the
        // middle of the row with nothing beside it.
        HStack(
            alignment: dynamicTypeSize.isAccessibilitySize ? .top : .firstTextBaseline, spacing: 6
        ) {
            Text(subject)
                .font(.subheadline)
                .fontWeight(thread.isUnread ? .semibold : .regular)
                .foregroundStyle(.primary)
                // The subject is the one line worth reading in full. At large
                // sizes it gets a second line rather than an ellipsis.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

            Spacer(minLength: 4)

            star
        }
    }

    /// A control when the list can act on it, a plain indicator when it
    /// cannot — never a button that looks tappable and does nothing.
    @ViewBuilder
    private var star: some View {
        if let onToggleStar {
            Button(action: onToggleStar) {
                starIcon
            }
            .buttonStyle(.plain)
            // The glyph is well under the 44pt minimum on its own.
            .frame(width: 30, height: 26)
            .contentShape(.rect)
            .accessibilityHidden(true)
        } else if thread.isFlagged {
            starIcon
        }
    }

    private var starIcon: some View {
        Image(systemName: thread.isFlagged ? "star.fill" : "star")
            .font(.caption)
            .foregroundStyle(thread.isFlagged ? Color.orange : Color.secondary.opacity(0.45))
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
        if thread.hasAttachment || accountLabel != nil || thread.snoozedUntil != nil {
            HStack(spacing: 6) {
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

                if thread.hasAttachment {
                    Image(systemName: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let accountLabel {
                    Text(accountLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.top, 2)
            .accessibilityHidden(true)
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
        if let accountLabel { parts.append(accountLabel) }

        parts.append(thread.latestReceivedAt.formatted(date: .abbreviated, time: .shortened))

        return parts.joined(separator: ", ")
    }
}

#endif
