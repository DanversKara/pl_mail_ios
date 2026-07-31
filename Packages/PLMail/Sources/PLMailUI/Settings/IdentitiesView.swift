#if os(iOS)

public import PLMailCore

import SwiftUI

/// The addresses this login can send from.
///
/// Two things are worth knowing before reading the layout. The **name** is
/// editable and goes to the server as `Identity/set`; it is what recipients
/// see beside the address. The **signature** is not editable, because plMail
/// has nowhere to keep one — see ``IdentityEditor``. Showing a disabled field
/// with a sentence explaining why beats showing an enabled one that discards
/// what is typed into it, and beats hiding the concept altogether from someone
/// who came here looking for exactly that.
public struct IdentitiesView: View {
    @State private var editor: IdentityEditor

    public init(sync: MailSyncService, store: SyncStore) {
        _editor = State(
            wrappedValue: IdentityEditor(
                client: sync.jmapClient, store: store, accounts: sync.accounts))
    }

    public var body: some View {
        List {
            if let failure = editor.refreshFailure {
                Section {
                    Label {
                        Text(verbatim: failure)
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            ForEach(editor.groups) { group in
                Section {
                    ForEach(group.identities) { identity in
                        NavigationLink {
                            IdentityDetailView(
                                identity: identity, group: group, editor: editor)
                        } label: {
                            row(for: identity)
                        }
                    }
                } header: {
                    // Only worth a header when there is more than one account
                    // to tell apart. A single-account user does not need to be
                    // told which account their only address belongs to.
                    if editor.groups.count > 1 {
                        Text(verbatim: group.accountName)
                    }
                }
            }
        }
        .overlay {
            if editor.isLoading {
                ProgressView()
            } else if editor.groups.isEmpty {
                ContentUnavailableView(
                    .ui("No sending addresses"),
                    systemImage: "at.badge.plus",
                    description: Text(
                        .ui(
                            "The addresses you can send from appear here once your accounts have synced."
                        ))
                )
            }
        }
        .navigationTitle(.ui("Sending addresses"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await editor.load() }
        .refreshable { await editor.refresh() }
    }

    private func row(for identity: IdentitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The name, or the address when there is no name — never an empty
            // row, which is what a nameless identity used to render as.
            Text(verbatim: identity.name?.isEmpty == false ? identity.name! : identity.email)

            if identity.name?.isEmpty == false {
                Text(verbatim: identity.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One address: what recipients see, and what the server will and will not
/// keep.
private struct IdentityDetailView: View {
    let identity: IdentitySnapshot
    let group: IdentityEditor.Group
    let editor: IdentityEditor

    @State private var name: String
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(identity: IdentitySnapshot, group: IdentityEditor.Group, editor: IdentityEditor) {
        self.identity = identity
        self.group = group
        self.editor = editor
        _name = State(initialValue: identity.name ?? "")
    }

    private var hasChanges: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != (identity.name ?? "")
    }

    private var signature: String? {
        guard let signature = identity.textSignature,
            signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }

        return signature
    }

    var body: some View {
        Form {
            Section {
                // Laid out as a labelled row rather than a bare field, so it
                // lines up with the address beneath it. A lone text box in a
                // form reads as "type something here" without saying what.
                LabeledContent {
                    TextField(.ui("Name"), text: $name)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text(.ui("Name"))
                }

                LabeledContent(.ui("Address"), value: identity.email)
            } footer: {
                Text(.ui("The name recipients see beside your address."))
            }

            Section {
                if let signature {
                    Text(verbatim: signature)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text(.ui("No signature"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(.ui("Signature"))
            } footer: {
                // Said plainly rather than dressed up as "coming soon". The
                // server rejects the property; no client can set it, including
                // the web UI, so there is nothing here to wait for.
                Text(
                    .ui(
                        "plMail keeps no signature for an address, so this cannot be changed here or in the web interface. If your server ever does send one, it is added below what you write."
                    ))
            }
        }
        .navigationTitle(Text(verbatim: identity.email))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(.ui("Save")) { save() }
                    .disabled(hasChanges == false || isSaving)
            }
        }
        .alert(
            .ui("Not saved"),
            isPresented: Binding(
                get: { editor.saveFailure != nil },
                set: { if $0 == false { editor.dismissSaveFailure() } })
        ) {
            Button(.ui("OK"), role: .cancel) { editor.dismissSaveFailure() }
        } message: {
            Text(verbatim: editor.saveFailure ?? "")
        }
    }

    private func save() {
        isSaving = true

        Task {
            let saved = await editor.rename(identity, in: group, to: name)

            isSaving = false

            // Stays open on a failure, with the alert over it and the typed
            // name still in the field: popping back would throw away what was
            // written and leave the user to retype it.
            if saved { dismiss() }
        }
    }
}

#endif
