#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// Making, renaming and deleting labels.
///
/// Grouped by account rather than collapsed by label id, unlike the sidebar. A
/// JMAP Mailbox is a per-account *binding*, so "Work" reachable from three
/// accounts is three things that can be renamed and deleted independently —
/// and a screen whose whole job is to rename and delete has to show what it is
/// actually acting on. The sidebar collapses them because there it is one
/// place to look at mail; this is not that.
///
/// System labels appear, greyed and unactionable, rather than being filtered
/// out. A list of "your labels" that silently omits Inbox invites the user to
/// go looking for the screen that does have it.
struct LabelManagerView: View {
    let sync: MailSyncService
    let labels: LabelActions

    @Environment(\.dismiss) private var dismiss

    @State private var creatingIn: AccountSnapshot?
    @State private var renaming: MailboxSnapshot?
    @State private var deleting: MailboxSnapshot?
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(sync.accounts) { account in
                    Section {
                        ForEach(rows(for: account), id: \.id) { mailbox in
                            row(mailbox)
                        }

                        Button {
                            draftName = ""
                            labels.dismissFailure()
                            creatingIn = account
                        } label: {
                            Label(.ui("New label"), systemImage: "plus.circle")
                        }
                        .disabled(labels.isBusy)
                    } header: {
                        Text(account.displayName)
                    }
                }
            }
            .navigationTitle(.ui("Labels"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Done")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { refusal }
            .sheet(item: $creatingIn) { account in
                LabelNameSheet(
                    title: .ui("New label"),
                    confirm: .ui("Create"),
                    name: $draftName,
                    labels: labels,
                    accountKey: account.accountKey,
                    mailboxes: sync.mailboxes
                ) { name in
                    await labels.create(named: name, accountID: account.accountID) != nil
                }
            }
            .sheet(item: $renaming) { mailbox in
                LabelNameSheet(
                    title: .ui("Rename label"),
                    confirm: .ui("Save"),
                    name: $draftName,
                    labels: labels,
                    accountKey: mailbox.accountKey,
                    mailboxes: sync.mailboxes,
                    // Its own name is not a clash with itself.
                    ignoring: mailbox.mailboxID
                ) { name in
                    guard let accountID = accountID(for: mailbox) else { return false }

                    return await labels.rename(
                        mailbox.mailboxID, to: name, accountID: accountID)
                }
            }
            .alert(
                .ui("Delete this label?"),
                isPresented: Binding(
                    get: { deleting != nil },
                    set: { if $0 == false { deleting = nil } }
                ),
                presenting: deleting
            ) { mailbox in
                Button(.ui("Delete"), role: .destructive) {
                    guard let accountID = accountID(for: mailbox) else { return }

                    Task { await labels.delete(mailbox.mailboxID, accountID: accountID) }
                }

                Button(.ui("Cancel"), role: .cancel) {}
            } message: { mailbox in
                // Says what survives, because that is the part people fear.
                // Deleting a label in plMail detaches it; it does not delete
                // mail, and the messages stay wherever else they are.
                Text(
                    .ui(
                        "“\(mailbox.name)” will be removed from this account. No mail is deleted — the messages keep every other label they carry."
                    ))
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ mailbox: MailboxSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: mailbox.role?.symbolName ?? "tag.fill")
                .foregroundStyle(
                    MailboxSidebarView.tint(for: mailbox.role)
                        ?? AvatarPalette.color(
                            for: mailbox.labelID?.rawValue ?? mailbox.name))

            Text(mailbox.name)
                .foregroundStyle(mailbox.mayRename ? .primary : .secondary)

            Spacer(minLength: 8)

            // Named rather than left to the greying-out alone: "why can't I
            // rename this" is answered here instead of by trying.
            if mailbox.mayRename == false && mailbox.mayDelete == false {
                Text(.ui("Built in"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            if mailbox.mayDelete {
                Button(role: .destructive) {
                    labels.dismissFailure()
                    deleting = mailbox
                } label: {
                    Label(.ui("Delete"), systemImage: "trash")
                }
            }

            if mailbox.mayRename {
                Button {
                    draftName = mailbox.name
                    labels.dismissFailure()
                    renaming = mailbox
                } label: {
                    Label(.ui("Rename"), systemImage: "pencil")
                }
                .tint(.accentColor)
            }
        }
    }

    @ViewBuilder
    private var refusal: some View {
        if let failure = labels.failure {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(failure)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(.ui("Dismiss")) { labels.dismissFailure() }
                    .font(.footnote)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Contents

    /// This account's mailboxes: custom labels first, since they are what can
    /// be acted on here, then the built-ins.
    private func rows(for account: AccountSnapshot) -> [MailboxSnapshot] {
        sync.mailboxes
            .filter { $0.accountKey == account.accountKey }
            .sorted { first, second in
                if (first.role == nil) != (second.role == nil) {
                    return first.role == nil
                }

                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    private func accountID(for mailbox: MailboxSnapshot) -> AccountID? {
        sync.accounts.first { $0.accountKey == mailbox.accountKey }?.accountID
    }
}

/// The one text field, shared by Create and Rename.
///
/// The two differ only in their words and in what they do on confirm, and a
/// second copy of the validation is a second place for it to drift from the
/// server's rules.
struct LabelNameSheet: View {
    let title: LocalizedStringResource
    let confirm: LocalizedStringResource
    @Binding var name: String
    let labels: LabelActions
    let accountKey: String
    let mailboxes: [MailboxSnapshot]
    var ignoring: MailboxID?
    let perform: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(.ui("Label name"), text: $name)
                        .focused($isFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .onSubmit { if isValid { submit() } }
                } footer: {
                    // Said while typing rather than after pressing. Both of
                    // these are rules the server enforces, and finding out
                    // from a refusal means retyping a name already gone from
                    // the field.
                    if let complaint {
                        Text(complaint)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: confirm)) { submit() }
                        .disabled(isValid == false || labels.isBusy)
                }
            }
            .task { isFocused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        let name = name

        Task {
            // Only closes if the server agreed. A sheet that dismisses on a
            // refusal drops the user back to a list unchanged, with the
            // explanation behind them.
            if await perform(name) { dismiss() }
        }
    }

    private var complaint: String? {
        // Silent on an empty field: the user has not typed anything wrong
        // yet, they have simply not finished. The button is disabled, which
        // says enough.
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        // Already localised by PLMailCore, which owns the rule and therefore
        // owns the wording of it.
        if let complaint = LabelActions.complaint(about: name) { return complaint }

        if isTaken {
            return String(localized: .ui("There's already a label with that name here."))
        }

        return nil
    }

    private var isTaken: Bool {
        LabelActions.nameIsTaken(
            name,
            parentID: nil,
            accountKey: accountKey,
            among: mailboxes.filter { $0.mailboxID != ignoring }
        )
    }

    private var isValid: Bool {
        LabelActions.complaint(about: name) == nil && isTaken == false
    }
}

#endif
