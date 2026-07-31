#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// Labelling a whole selection.
///
/// Deliberately not the same view as ``LabelPickerView``. That one is a
/// checklist showing what a conversation already carries; a selection has no
/// single such state — forty threads can each carry a different set — so
/// showing checkmarks here would have to invent an answer. This offers the two
/// unambiguous verbs instead, and closes after one, because a selection is
/// usually being labelled and cleared rather than curated.
///
/// Labels are listed by their **user-scoped** id, so one row covers every
/// account in the selection. Accounts with no binding for the label are skipped
/// on the way out rather than blocked here — a label used in one mailbox and
/// never in another is the normal case, not an error.
struct BulkLabelPickerView: View {
    let targets: [ActionTarget]
    let sync: MailSyncService
    let actions: MailActions
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if labels.isEmpty {
                    ContentUnavailableView {
                        Label(.ui("No labels yet"), systemImage: "tag")
                    } description: {
                        Text(.ui("Labels you create in plMail's web UI appear here."))
                    }
                } else {
                    ForEach(labels) { label in
                        Section {
                            Button {
                                apply(true, label)
                            } label: {
                                Label(.ui("Apply"), systemImage: "plus.circle")
                            }

                            Button(role: .destructive) {
                                apply(false, label)
                            } label: {
                                Label(.ui("Remove"), systemImage: "minus.circle")
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Image(systemName: "tag.fill")
                                    .foregroundStyle(AvatarPalette.color(for: label.id.rawValue))
                                Text(label.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle(.ui("Label \(targets.count) selected"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text(.ui("Filter labels")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply(_ isApplied: Bool, _ label: LabelRow) {
        let targets = targets

        Task {
            await actions.perform(
                .setLabel(isApplied, label.id, name: label.name), on: targets)
        }

        onFinish()
        dismiss()
    }

    /// Every custom label across the accounts in the selection, collapsed by
    /// user-scoped id so "Work" is one row rather than one per account.
    private var labels: [LabelRow] {
        let accounts = Set(targets.map(\.accountKey))
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var byLabel: [LabelID: LabelRow] = [:]

        for mailbox in sync.mailboxes {
            guard
                accounts.contains(mailbox.accountKey),
                mailbox.role == nil,
                let labelID = mailbox.labelID
            else { continue }

            byLabel[labelID] = LabelRow(id: labelID, name: mailbox.name)
        }

        return byLabel.values
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    struct LabelRow: Identifiable {
        let id: LabelID
        let name: String
    }
}

#endif
