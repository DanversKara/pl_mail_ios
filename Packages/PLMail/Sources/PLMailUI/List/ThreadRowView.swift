#if os(iOS)

public import PLMailCore

import SwiftUI

/// One conversation in a list.
///
/// A single state-driven component, mirroring the web UI's `_thread_row`:
/// every affordance keys off the thread's state rather than there being a
/// read row and an unread row. That is what keeps the two clients looking
/// like the same product as the states multiply.
public struct ThreadRowView: View {
    let thread: StoredThread
    /// Shown only in a unified feed, where "which mailbox is this from?"
    /// is a real question. In a single-account list it is noise.
    let accountLabel: String?

    public init(thread: StoredThread, accountLabel: String? = nil) {
        self.thread = thread
        self.accountLabel = accountLabel
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            unreadIndicator

            VStack(alignment: .leading, spacing: 3) {
                topLine
                subjectLine
                snippetLine
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var unreadIndicator: some View {
        Circle()
            .fill(thread.isUnread ? Color.accentColor : .clear)
            .frame(width: 8, height: 8)
            .padding(.top, 6)
            .accessibilityHidden(true)
    }

    private var topLine: some View {
        HStack(spacing: 6) {
            Text(participants)
                .font(.subheadline)
                .fontWeight(thread.isUnread ? .semibold : .regular)
                .lineLimit(1)

            if thread.messageCount > 1 {
                Text("\(thread.messageCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }

            Spacer(minLength: 4)

            if thread.isFlagged {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }

            Text(relativeDate)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var subjectLine: some View {
        HStack(spacing: 4) {
            if thread.hasAttachment {
                Image(systemName: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Text(subject)
                .font(.subheadline)
                .fontWeight(thread.isUnread ? .medium : .regular)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var snippetLine: some View {
        if thread.snippet.isEmpty == false {
            Text(thread.snippet)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        if let accountLabel {
            Text(accountLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
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

    /// The visual affordances are icons and weight, none of which VoiceOver
    /// can read, so the state is spelled out here instead.
    private var accessibilityDescription: String {
        var parts: [String] = []

        if thread.isUnread { parts.append("Unread") }
        if thread.isFlagged { parts.append("Starred") }

        parts.append("From \(participants)")
        parts.append(subject)

        if thread.messageCount > 1 { parts.append("\(thread.messageCount) messages") }
        if thread.hasAttachment { parts.append("Has attachment") }

        parts.append(thread.latestReceivedAt.formatted(date: .abbreviated, time: .shortened))

        return parts.joined(separator: ", ")
    }
}

#endif
