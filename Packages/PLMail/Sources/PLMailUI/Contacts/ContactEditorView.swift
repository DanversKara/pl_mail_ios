#if os(iOS)

import JMAPKit
import PLMailCore
import SwiftUI

/// BearerMail: add or change a contact — the iOS twin of the Android
/// contact editor.
///
/// Name and work, then any number of email addresses, phone numbers and
/// postal addresses, each labelled Home, Work or Other, then tags and notes.
/// Save is enabled once there is a name.
struct ContactEditorView: View {
    let service: ContactsService
    let contactID: ContactID?

    @State private var draft = ContactDraft()
    @State private var newTag = ""
    @State private var isSaving = false
    @State private var hasLoaded = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private static let labels = ["home", "work", "other"]

    var body: some View {
        let palette = theme.palette(for: colorScheme)

        Form {
            Section {
                TextField(text: $draft.displayName) { Text(.ui("Name")) }
                    .textContentType(.name)
                TextField(text: $draft.givenName) { Text(.ui("First name")) }
                    .textContentType(.givenName)
                TextField(text: $draft.familyName) { Text(.ui("Last name")) }
                    .textContentType(.familyName)
                TextField(text: $draft.nickname) { Text(.ui("Nickname")) }
            }
            .listRowBackground(palette.raised.color)

            Section {
                TextField(text: $draft.company) { Text(.ui("Company")) }
                    .textContentType(.organizationName)
                TextField(text: $draft.jobTitle) { Text(.ui("Job title")) }
                    .textContentType(.jobTitle)
            }
            .listRowBackground(palette.raised.color)

            Section {
                ForEach(draft.emails.indices, id: \.self) { index in
                    HStack {
                        labelPicker($draft.emails[index].label)
                        TextField(text: $draft.emails[index].email) { Text(.ui("Email")) }
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .onDelete { draft.emails.remove(atOffsets: $0) }
                addButton(.ui("Add email")) { draft.emails.append(ContactEmail()) }
            } header: {
                Text(.ui("Email"))
            }
            .listRowBackground(palette.raised.color)

            Section {
                ForEach(draft.phones.indices, id: \.self) { index in
                    HStack {
                        labelPicker($draft.phones[index].label)
                        TextField(text: $draft.phones[index].phone) { Text(.ui("Phone")) }
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                    }
                }
                .onDelete { draft.phones.remove(atOffsets: $0) }
                addButton(.ui("Add phone")) { draft.phones.append(ContactPhone()) }
            } header: {
                Text(.ui("Phone"))
            }
            .listRowBackground(palette.raised.color)

            Section {
                ForEach(draft.addresses.indices, id: \.self) { index in
                    VStack(alignment: .leading) {
                        labelPicker($draft.addresses[index].label)
                        TextField(text: text($draft.addresses[index].street)) {
                            Text(.ui("Street"))
                        }
                        TextField(text: text($draft.addresses[index].city)) { Text(.ui("City")) }
                        TextField(text: text($draft.addresses[index].region)) {
                            Text(.ui("State or region"))
                        }
                        TextField(text: text($draft.addresses[index].postcode)) {
                            Text(.ui("Postcode"))
                        }
                        TextField(text: text($draft.addresses[index].country)) {
                            Text(.ui("Country"))
                        }
                    }
                }
                .onDelete { draft.addresses.remove(atOffsets: $0) }
                addButton(.ui("Add address")) { draft.addresses.append(ContactAddress()) }
            } header: {
                Text(.ui("Address"))
            }
            .listRowBackground(palette.raised.color)

            Section {
                ForEach(draft.tags, id: \.self) { tag in
                    Text(verbatim: tag)
                }
                .onDelete { draft.tags.remove(atOffsets: $0) }
                HStack {
                    TextField(text: $newTag) { Text(.ui("New tag")) }
                        .onSubmit(addTag)
                    Button(.ui("Add"), action: addTag)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text(.ui("Tags"))
            }
            .listRowBackground(palette.raised.color)

            Section {
                TextField(text: $draft.notes, axis: .vertical) { Text(.ui("Notes")) }
                    .lineLimit(3...)
            } header: {
                Text(.ui("Notes"))
            }
            .listRowBackground(palette.raised.color)

            if case .refused(_)? = service.failure {
                Text(.ui("The server did not accept this contact. Check the email addresses."))
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(palette.surface.color)
        .navigationTitle(Text(contactID == nil ? LocalizedStringResource.ui("New contact") : .ui("Edit contact")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(.ui("Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(.ui("Save")) { Task { await save() } }
                    .disabled(canSave == false || isSaving)
            }
        }
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty == false
            || draft.givenName.trimmingCharacters(in: .whitespaces).isEmpty == false
            || draft.familyName.trimmingCharacters(in: .whitespaces).isEmpty == false
    }

    private func labelPicker(_ selection: Binding<String>) -> some View {
        Picker(selection: selection) {
            ForEach(Self.labels, id: \.self) { label in
                Text(ContactDetailView.labelName(label)).tag(label)
            }
        } label: {
            Text(.ui("Label"))
        }
        .labelsHidden()
        .fixedSize()
    }

    private func addButton(_ title: LocalizedStringResource, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    /// An optional address part as a plain text binding: empty means absent.
    private func text(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0 })
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        newTag = ""
        guard tag.isEmpty == false, draft.tags.contains(tag) == false else { return }
        draft.tags.append(tag)
    }

    private func load() {
        guard hasLoaded == false else { return }
        hasLoaded = true
        if let contactID, let contact = service.contact(id: contactID) {
            draft = ContactDraft(contact)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        var draft = draft
        // A name built from its parts when only the parts were typed.
        if draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.displayName = [draft.givenName, draft.familyName]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.isEmpty == false }
                .joined(separator: " ")
        }
        // The first address and number are the primary ones unless one was chosen.
        if draft.emails.contains(where: \.isPrimary) == false, draft.emails.isEmpty == false {
            draft.emails[0].isPrimary = true
        }
        if draft.phones.contains(where: \.isPrimary) == false, draft.phones.isEmpty == false {
            draft.phones[0].isPrimary = true
        }

        let ok: Bool
        if let contactID {
            ok = await service.update(contactID, draft)
        } else {
            ok = await service.create(draft) != nil
        }
        if ok { dismiss() }
    }
}

#endif
