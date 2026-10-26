#if os(iOS)

import JMAPKit
import PLMailCore
import SwiftUI

/// BearerMail: one person's page — the iOS twin of the Android contact
/// detail.
///
/// Their addresses (tap to write), numbers (tap to call), postal addresses
/// (tap for Maps), notes, tags, and the mail exchanged with them, newest
/// first. Edit and Delete in the toolbar.
struct ContactDetailView: View {
    let service: ContactsService
    let contactID: ContactID

    @State private var recent: [ContactReferenceEmail] = []
    @State private var isEditing = false
    @State private var isConfirmingDelete = false

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = theme.palette(for: colorScheme)

        Group {
            if let contact = service.contact(id: contactID) {
                List {
                    header(contact)
                        .listRowBackground(Color.clear)

                    if contact.emails.isEmpty == false {
                        Section {
                            ForEach(Array(contact.emails.enumerated()), id: \.offset) { _, entry in
                                row(
                                    label: Self.labelName(entry.label), value: entry.email,
                                    systemImage: "envelope"
                                ) {
                                    if let url = URL(string: "mailto:\(entry.email)") { openURL(url) }
                                }
                            }
                        } header: {
                            Text(.ui("Email"))
                        }
                        .listRowBackground(palette.raised.color)
                    }

                    if contact.phones.isEmpty == false {
                        Section {
                            ForEach(Array(contact.phones.enumerated()), id: \.offset) { _, entry in
                                row(
                                    label: Self.labelName(entry.label), value: entry.phone,
                                    systemImage: "phone"
                                ) {
                                    let digits = entry.phone.filter { $0.isNumber || $0 == "+" }
                                    if let url = URL(string: "tel:\(digits)") { openURL(url) }
                                }
                            }
                        } header: {
                            Text(.ui("Phone"))
                        }
                        .listRowBackground(palette.raised.color)
                    }

                    if contact.addresses.isEmpty == false {
                        Section {
                            ForEach(Array(contact.addresses.enumerated()), id: \.offset) {
                                _, entry in
                                row(
                                    label: Self.labelName(entry.label), value: entry.oneLine,
                                    systemImage: "map"
                                ) {
                                    let query =
                                        entry.oneLine.addingPercentEncoding(
                                            withAllowedCharacters: .urlQueryAllowed) ?? ""
                                    if let url = URL(string: "maps://?q=\(query)") { openURL(url) }
                                }
                            }
                        } header: {
                            Text(.ui("Address"))
                        }
                        .listRowBackground(palette.raised.color)
                    }

                    if let notes = contact.notes, notes.isEmpty == false {
                        Section {
                            Text(verbatim: notes)
                                .textSelection(.enabled)
                        } header: {
                            Text(.ui("Notes"))
                        }
                        .listRowBackground(palette.raised.color)
                    }

                    if recent.isEmpty == false {
                        Section {
                            ForEach(recent) { mail in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: mail.subject?.isEmpty == false ? (mail.subject ?? "") : "—")
                                        .lineLimit(1)
                                    if let date = mail.date.flatMap(Self.parse) {
                                        Text(date, format: .dateTime.day().month().year())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text(.ui("Recent mail"))
                        }
                        .listRowBackground(palette.raised.color)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(palette.surface.color)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(.ui("Edit")) { isEditing = true }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Label {
                                Text(.ui("Delete contact"))
                            } icon: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
                .confirmationDialog(
                    Text(.ui("Delete this contact?")), isPresented: $isConfirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button(role: .destructive) {
                        Task {
                            if await service.delete(contactID) { dismiss() }
                        }
                    } label: {
                        Text(.ui("Delete contact"))
                    }
                } message: {
                    Text(.ui("It is removed from your address book everywhere. Mail you exchanged stays."))
                }
                .sheet(isPresented: $isEditing) {
                    NavigationStack {
                        ContactEditorView(service: service, contactID: contactID)
                    }
                    .themedSheet(theme, reduceMotion: false)
                }
            } else {
                ContentUnavailableView(
                    .ui("This contact is gone"), systemImage: "person.crop.circle.badge.xmark")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: contactID) {
            recent = await service.recentMail(for: contactID)
        }
    }

    private func header(_ contact: Contact) -> some View {
        VStack(spacing: 8) {
            ContactAvatar(contact: contact, size: 84)
            Text(verbatim: contact.displayName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            let work = [contact.jobTitle, contact.company]
                .compactMap { $0 }
                .filter { $0.isEmpty == false }
                .joined(separator: " · ")
            if work.isEmpty == false {
                Text(verbatim: work)
                    .foregroundStyle(.secondary)
            }
            if contact.tags.isEmpty == false {
                HStack(spacing: 6) {
                    ForEach(contact.tags, id: \.self) { tag in
                        Text(verbatim: tag)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.quaternary))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func row(
        label: LocalizedStringResource, value: String, systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: value)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: systemImage)
                    .foregroundStyle(.themeAccent)
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label {
                    Text(.ui("Copy"))
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
    }

    static func labelName(_ label: String) -> LocalizedStringResource {
        switch label {
        case "home": .ui("Home")
        case "work": .ui("Work")
        default: .ui("Other")
        }
    }

    private static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

#endif
