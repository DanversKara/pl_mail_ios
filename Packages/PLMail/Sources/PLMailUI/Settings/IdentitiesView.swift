#if os(iOS)

public import PLMailCore

import SwiftUI

/// The addresses this login can send from.
///
/// Two things are worth knowing before reading the layout. The **name** is
/// editable and goes to the server as `Identity/set`; it is what recipients see
/// beside the address. The **signature** is editable too — this screen used to
/// say it was not, on the strength of a doc comment describing a server version
/// that had been superseded. It is stored in the same per-alias setting the web
/// composer reads, so a signature written here is the one the browser signs
/// with.
///
/// The one thing not offered is editing a signature that carries real markup
/// through a plain-text box. See ``SignatureText`` for why: saving it would
/// flatten a signature someone built in the web interface, and doing that on a
/// Save the user pressed only to change a name is the worst version of it.
public struct IdentitiesView: View {
    @State private var editor: IdentityEditor
    /// BearerMail: the account a new alias is being made on.
    @State private var aliasGroup: IdentityEditor.Group?

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

                    // BearerMail: a new alias on this account's domain.
                    if editor.aliasDomain(for: group) != nil {
                        Button {
                            aliasGroup = group
                        } label: {
                            Label {
                                Text(.ui("New alias"))
                            } icon: {
                                Image(systemName: "plus.circle")
                            }
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
        .sheet(item: $aliasGroup) { group in
            NavigationStack {
                NewAliasView(editor: editor, group: group)
            }
        }
    }

    private func row(for identity: IdentitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The name, or the address when there is no name — never an empty
            // row, which is what a nameless identity used to render as.
            let named = identity.name.flatMap { $0.isEmpty ? nil : $0 }
            Text(verbatim: named ?? identity.email)

            if identity.name?.isEmpty == false {
                Text(verbatim: identity.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One address: what recipients see, and what it signs with.
private struct IdentityDetailView: View {
    let identity: IdentitySnapshot
    let group: IdentityEditor.Group
    let editor: IdentityEditor

    @State private var name: String
    @State private var signature: String
    /// The signature as it stood when the screen opened, so Save can tell a
    /// genuine edit from a screen that was merely visited. Without it, opening
    /// this screen and pressing Save to change a name would rewrite the
    /// signature with its own round trip through plain text.
    @State private var originalSignature: String
    /// False when the stored signature carries markup a plain-text field would
    /// destroy. The field is then not offered at all — see ``SignatureText``.
    @State private var isEditable: Bool
    @State private var isSaving = false
    @State private var isConfirmingReplace = false
    @Environment(\.dismiss) private var dismiss

    init(identity: IdentitySnapshot, group: IdentityEditor.Group, editor: IdentityEditor) {
        self.identity = identity
        self.group = group
        self.editor = editor

        let editable = SignatureText.isPlainTextEquivalent(identity.htmlSignature)
        let text = SignatureText.plainText(fromHTML: identity.htmlSignature)

        _name = State(initialValue: identity.name ?? "")
        _signature = State(initialValue: text)
        _originalSignature = State(initialValue: text)
        _isEditable = State(initialValue: editable)
    }

    private var nameChanged: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != (identity.name ?? "")
    }

    private var signatureChanged: Bool {
        isEditable && signature != originalSignature
    }

    private var hasChanges: Bool { nameChanged || signatureChanged }

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

            signatureSection
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
        .confirmationDialog(
            .ui("Replace this signature?"),
            isPresented: $isConfirmingReplace,
            titleVisibility: .visible
        ) {
            Button(.ui("Replace"), role: .destructive) {
                signature = SignatureText.plainText(fromHTML: identity.htmlSignature)
                originalSignature = signature
                isEditable = true
            }
            Button(.ui("Cancel"), role: .cancel) {}
        } message: {
            Text(
                .ui(
                    "The formatting, links and images in it are removed. What you write here replaces it everywhere, including in the web interface."
                ))
        }
    }

    // MARK: - Signature

    @ViewBuilder
    private var signatureSection: some View {
        Section {
            if isEditable {
                // A `TextEditor` rather than a `TextField`: a signature is
                // several lines and a single-line field would scroll the
                // beginning out of sight while it was being typed.
                TextEditor(text: $signature)
                    .frame(minHeight: 92)
                    .font(.callout)
                    .autocorrectionDisabled()
                    .accessibilityLabel(.ui("Signature"))
            } else {
                Text(verbatim: SignatureText.plainText(fromHTML: identity.htmlSignature))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Button(.ui("Replace with plain text")) { isConfirmingReplace = true }
            }

            if identity.hasStoredSignature {
                Button(.ui("Remove signature"), role: .destructive) { clear() }
                    .disabled(isSaving)
            }
        } header: {
            Text(.ui("Signature"))
        } footer: {
            if isEditable {
                Text(
                    .ui(
                        "Added below what you write, in this app and in the web interface. Leaving it empty means this address signs with nothing, even when the account itself has a signature."
                    ))
            } else {
                // Said plainly. The alternative — quietly offering a text box
                // and flattening the signature on Save — is the failure this
                // whole branch exists to avoid.
                Text(
                    .ui(
                        "This signature was written with formatting, so it can't be edited here without losing it. Change it in the web interface, or replace it with plain text."
                    ))
            }
        }
    }

    // MARK: - Saving

    private func save() {
        isSaving = true

        Task {
            var saved = true

            // Name first: it is the cheaper failure to recover from, and a
            // signature saved against a name the server refused would leave
            // the screen half applied with no way to tell which half.
            if nameChanged {
                saved = await editor.rename(identity, in: group, to: name)
            }

            if saved && signatureChanged {
                saved = await editor.save(signature: signature, for: identity, in: group)
            }

            isSaving = false

            // Stays open on a failure, with the alert over it and what was
            // typed still in the fields: popping back would throw it away and
            // leave the user to retype it.
            if saved { dismiss() }
        }
    }

    private func clear() {
        isSaving = true

        Task {
            let cleared = await editor.clearSignature(for: identity, in: group)

            isSaving = false

            if cleared { dismiss() }
        }
    }
}

/// BearerMail: make a new alias — the iOS twin of Android's quick alias.
///
/// A local part (typed, or a random one, optionally starting with a word
/// from the label) on the account's own domain, and a display name. The new
/// address is ready to send from as soon as it is saved.
struct NewAliasView: View {
    let editor: IdentityEditor
    let group: IdentityEditor.Group

    @State private var localPart = ""
    @State private var name = ""
    @State private var isSaving = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let domain = editor.aliasDomain(for: group) ?? ""

        Form {
            Section {
                HStack(spacing: 2) {
                    TextField(text: $localPart) { Text(.ui("Address")) }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    Text(verbatim: "@\(domain)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button {
                    localPart = IdentityEditor.randomAliasLocalPart(label: name)
                } label: {
                    Label {
                        Text(.ui("Make a random one"))
                    } icon: {
                        Image(systemName: "dice")
                    }
                }
            } footer: {
                Text(.ui("A random address is handy for sign-ups: if it starts getting spam, you know who shared it."))
            }

            Section {
                TextField(text: $name) { Text(.ui("Name recipients see (optional)")) }
            }

            if let failure = editor.saveFailure {
                Text(verbatim: failure)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
        .navigationTitle(Text(.ui("New alias")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(.ui("Cancel")) {
                    editor.dismissSaveFailure()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(.ui("Create")) {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        if await editor.createAlias(
                            localPart: localPart, name: trimmed.isEmpty ? nil : trimmed,
                            in: group) != nil
                        {
                            dismiss()
                        }
                    }
                }
                .disabled(
                    isSaving || IdentityEditor.isValidAliasLocalPart(localPart) == false)
            }
        }
    }
}

#endif
