#if os(iOS)

public import PLMailCore

import SwiftUI

/// What is written but not yet gone.
///
/// Deliberately a place you can look rather than a status line that flickers
/// past: the whole point of the queue is that a message survives a closed
/// composer, a dead uplink and a relaunch, and a queue you cannot inspect is
/// indistinguishable from mail that was silently dropped.
public struct OutboxView: View {
    private let outbox: OutboxSender
    @State private var messages: [Outbox.PendingMessage] = []
    @Environment(\.dismiss) private var dismiss

    public init(outbox: OutboxSender) {
        self.outbox = outbox
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(messages) { message in
                        row(for: message)
                    }
                } footer: {
                    // Only when it applies. Mail waiting for a server needs no
                    // explanation of the clock.
                    if messages.contains(where: { $0.sendAfter != nil }) {
                        Text(.ui(SendLaterSheet.caveat))
                    }
                }
            }
            .overlay {
                if messages.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text(.ui("Nothing waiting"))
                        } icon: {
                            Image(systemName: "tray")
                        }
                    } description: {
                        Text(.ui("Everything you've written has been sent."))
                    }
                }
            }
            .navigationTitle(Text(.ui("Outbox")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Done")) { dismiss() }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button(.ui("Try now")) { outbox.drain() }
                        .disabled(messages.isEmpty || outbox.isSending)
                }
            }
            .task { await reload() }
            // The sender is what empties the queue, and it does so from a
            // detached task; watching its count is how this list learns a
            // message left without polling.
            .onChange(of: outbox.pendingCount) { _, _ in
                Task { await reload() }
            }
        }
    }

    private func row(for message: Outbox.PendingMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.displayRecipient.isEmpty ? "—" : message.displayRecipient)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(message.queuedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(message.subject.isEmpty ? String(localized: .ui("(no subject)")) : message.subject)
                .font(.subheadline)
                .lineLimit(1)

            // Stated rather than shown as a clock glyph and a time: a row that
            // is waiting on purpose and a row that is stuck look identical
            // otherwise, and the second is the one people worry about.
            if let sendAfter = message.sendAfter {
                Label(
                    String(localized: .ui("Waiting until \(SnoozeMenu.shortTime(sendAfter))")),
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let failure = message.lastFailure {
                // Named rather than reduced to a spinner: "waiting for the
                // server" and "the server refused this" call for entirely
                // different responses from the person who wrote it.
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if outbox.isSending, message.isDue() {
                Label {
                    Text(.ui("Sending…"))
                } icon: {
                    ProgressView().controlSize(.mini)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(.ui("Discard"), systemImage: "trash", role: .destructive) {
                Task { await outbox.discard(message.id) }
            }
        }
        .swipeActions(edge: .leading) {
            // The way out of a schedule that turned out to be wrong: send it
            // anyway. Discarding is the other, and it is on the side people
            // already swipe for it.
            if message.sendAfter != nil {
                Button(.ui("Send now"), systemImage: "paperplane") {
                    Task { await sendNow(message.id) }
                }
                .tint(.accentColor)
            }
        }
        // Both actions again, because a swipe is invisible until it is tried
        // and this is the screen someone opens when they are already unsure
        // what is happening to their mail.
        .contextMenu {
            if message.sendAfter != nil {
                Button(.ui("Send now"), systemImage: "paperplane") {
                    Task { await sendNow(message.id) }
                }
            }

            Button(.ui("Discard"), systemImage: "trash", role: .destructive) {
                Task { await outbox.discard(message.id) }
            }
        }
    }

    /// Reloads afterwards rather than waiting for the count to change: a send
    /// that fails leaves the message here, and the row would otherwise go on
    /// saying it was waiting for a time that has been cleared.
    private func sendNow(_ id: UUID) async {
        await outbox.sendNow(id)
        await reload()
    }

    private func reload() async {
        messages = await outbox.pending()
    }
}

#endif
