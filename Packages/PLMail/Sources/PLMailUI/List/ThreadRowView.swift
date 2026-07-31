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

    public init(
        thread: StoredThread,
        accountLabel: String? = nil,
        onToggleStar: (() -> Void)? = nil
    ) {
        self.thread = thread
        self.accountLabel = accountLabel
        self.onToggleStar = onToggleStar
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SenderAvatar(
                name: thread.participantsSummary,
                address: thread.participantsAddress,
                isUnread: thread.isUnread
            )
            // Optically aligned with the first line of text rather than its
            // box: the cap height sits a little below the top of the line.
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                topLine
                subjectLine
                snippetLine
                badges
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: thread.isFlagged ? "Unstar" : "Star") {
            onToggleStar?()
        }
    }

    private var topLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(participants)
                .font(.subheadline)
                .fontWeight(thread.isUnread ? .semibold : .regular)
                .foregroundStyle(thread.isUnread ? .primary : .secondary)
                .lineLimit(1)

            if thread.messageCount > 1 {
                Text("\(thread.messageCount)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }

            Spacer(minLength: 4)

            Text(relativeDate)
                .font(.caption)
                .fontWeight(thread.isUnread ? .medium : .regular)
                .foregroundStyle(thread.isUnread ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
        }
    }

    private var subjectLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(subject)
                .font(.subheadline)
                .fontWeight(thread.isUnread ? .semibold : .regular)
                .foregroundStyle(.primary)
                .lineLimit(1)

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
        if thread.snippet.isEmpty == false {
            Text(thread.snippet)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The row's quiet metadata. Kept on its own line so a long subject never
    /// competes with it for width, and omitted entirely when there is none —
    /// an empty line would make every row taller for the sake of a few.
    @ViewBuilder
    private var badges: some View {
        if thread.hasAttachment || accountLabel != nil {
            HStack(spacing: 6) {
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

        if thread.isUnread { parts.append("Unread") }
        if thread.isFlagged { parts.append("Starred") }

        parts.append("From \(participants)")
        parts.append(subject)

        if thread.messageCount > 1 { parts.append("\(thread.messageCount) messages") }
        if thread.hasAttachment { parts.append("Has attachment") }
        if let accountLabel { parts.append(accountLabel) }

        parts.append(thread.latestReceivedAt.formatted(date: .abbreviated, time: .shortened))

        return parts.joined(separator: ", ")
    }
}

#endif
