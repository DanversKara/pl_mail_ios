#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// Applying labels to a conversation.
///
/// Labels are what plMail is: not folders a message lives in one of, but tags
/// it carries any number of. So this is a checklist rather than a picker — the
/// list stays open, several labels can be toggled in a row, and each toggle is
/// its own undoable action rather than a batch applied on dismiss.
///
/// Only labels belonging to *this* conversation's account are offered. A
/// binding exists per account, and offering another account's would send an id
/// the server cannot resolve.
struct LabelPickerView: View {
    let target: ActionTarget
    let sync: MailSyncService
    let actions: MailActions
    let store: SyncStore

    @Environment(\.dismiss) private var dismiss

    /// Mirrors the store so a tap responds immediately. Re-read after each
    /// action rather than assumed, because a refusal puts the old value back
    /// and the checkmark has to follow it.
    @State private var applied: Set<String> = []
    @State private var isLoaded = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if labels.isEmpty {
                    ContentUnavailableView {
                        Label("No labels yet", systemImage: "tag")
                    } description: {
                        Text("Labels you create in plMail's web UI appear here.")
                    }
                } else {
                    ForEach(labels, id: \.mailboxID) { label in
                        row(for: label)
                    }
                }
            }
            .navigationTitle("Labels")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Filter labels")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                applied =
                    (try? await store.mailboxIDs(
                        threadID: target.threadID, accountKey: target.accountKey)) ?? []
                isLoaded = true
            }
            // The app's undo bar is attached to the list, which is *behind*
            // this sheet — so a refusal here would put its explanation
            // somewhere nobody can see, leaving a checkmark that silently
            // refused to move. This says it where it happened.
            .safeAreaInset(edge: .bottom) { refusal }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var refusal: some View {
        if let failure = actions.failure {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(failure)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }

    private func row(for label: MailboxSnapshot) -> some View {
        Button {
            Task { await toggle(label) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(
                        AvatarPalette.color(for: label.labelID?.rawValue ?? label.name))

                Text(label.name)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                // Nothing is shown as on or off until the store has actually
                // answered: an unchecked box that turns out to be checked
                // reads as the app having lost the label.
                if isLoaded {
                    Image(systemName: isApplied(label) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isApplied(label) ? Color.accentColor : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isApplied(label) ? [.isButton, .isSelected] : .isButton)
    }

    private func isApplied(_ label: MailboxSnapshot) -> Bool {
        applied.contains(label.mailboxID.rawValue)
    }

    private func toggle(_ label: MailboxSnapshot) async {
        let shouldApply = isApplied(label) == false

        await actions.setLabel(shouldApply, mailbox: label.mailboxID, named: label.name, target)

        // Re-read rather than toggling the local set: a refusal — removing the
        // last label a message has — leaves the store unchanged, and a
        // checkmark that moved anyway would be the app disagreeing with the
        // server about where the mail is.
        applied =
            (try? await store.mailboxIDs(
                threadID: target.threadID, accountKey: target.accountKey)) ?? applied
    }

    /// This account's custom labels. Roles are excluded: Inbox, Trash and Sent
    /// are reached by archiving, trashing and sending, and offering them as
    /// checkboxes would present two different ways to do the same thing that
    /// behave differently.
    private var labels: [MailboxSnapshot] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        return
            sync.mailboxes
            .filter { $0.accountKey == target.accountKey && $0.role == nil }
            .filter {
                trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

#endif
