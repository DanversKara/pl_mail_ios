#if os(iOS)

public import PLMailCore
import JMAPKit
import SwiftUI

/// BearerMail: the address book — the iOS twin of the Android app's
/// Contacts screen.
///
/// Everyone in alphabetical sections with an index down the side, search over
/// names, addresses, numbers and tags, tag chips to narrow it, and a + to add
/// someone. Tapping a person opens their page.
///
/// No `NavigationStack` of its own, like `NotesView`, so the phone can push it
/// and the iPad can wrap it in a cover.
public struct ContactsView: View {
    let service: ContactsService
    let close: (() -> Void)?

    @State private var query = ""
    @State private var tag: String?
    @State private var isAdding = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    public init(service: ContactsService, close: (() -> Void)? = nil) {
        self.service = service
        self.close = close
    }

    public var body: some View {
        let palette = theme.palette(for: colorScheme)

        List {
            if service.tags.isEmpty == false {
                tagBar
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if service.isAvailable == false && service.isLoading == false {
                ContentUnavailableView(
                    .ui("This server does not have contacts"),
                    systemImage: "person.crop.circle",
                    description: Text(.ui("Contacts need a BearerMail server with the address book.")))
                    .listRowBackground(Color.clear)
            } else if visible.isEmpty && service.isLoading == false {
                ContentUnavailableView(
                    query.isEmpty && tag == nil ? LocalizedStringResource.ui("No contacts yet") : .ui("No matching contacts"),
                    systemImage: "person.crop.circle",
                    description: Text(.ui("Tap + to add someone. Contacts sync with BearerMail on the web.")))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(sections, id: \.letter) { section in
                    Section {
                        ForEach(section.contacts) { contact in
                            NavigationLink {
                                ContactDetailView(service: service, contactID: contact.id)
                            } label: {
                                ContactRow(contact: contact, service: service)
                            }
                            .listRowBackground(palette.raised.color)
                        }
                    } header: {
                        Text(verbatim: section.letter)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(palette.surface.color)
        .navigationTitle(Text(.ui("Contacts")))
        .searchable(text: $query, prompt: Text(.ui("Search contacts")))
        .refreshable { await service.refresh() }
        .toolbar {
            if let close {
                ToolbarItem(placement: .topBarLeading) {
                    Button(.ui("Close"), systemImage: "xmark", action: close)
                }
            }
            if service.isAvailable {
                ToolbarItem(placement: .primaryAction) {
                    Button(.ui("New contact"), systemImage: "plus") { isAdding = true }
                }
            }
            if service.isAvailable {
                ToolbarItem(placement: .secondaryAction) {
                    NavigationLink {
                        DuplicatesView(service: service)
                    } label: {
                        Label {
                            Text(.ui("Find duplicates"))
                        } icon: {
                            Image(systemName: "person.2")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                ContactEditorView(service: service, contactID: nil)
            }
            .themedSheet(theme, reduceMotion: false)
        }
        .overlay {
            if service.isLoading && service.contacts.isEmpty {
                ProgressView()
            }
        }
        .task {
            if service.contacts.isEmpty { await service.load() }
        }
    }

    private var tagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(service.tags, id: \.self) { name in
                    let isOn = tag == name
                    Button {
                        tag = isOn ? nil : name
                    } label: {
                        Text(verbatim: name)
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    isOn
                                        ? theme.palette(for: colorScheme).accentSoft.color
                                        : theme.palette(for: colorScheme).sunken.color))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var visible: [Contact] {
        service.contacts
            .filter { tag == nil || $0.tags.contains(tag ?? "") }
            .filter { $0.matches(query) }
    }

    private struct LetterSection {
        var letter: String
        var contacts: [Contact]
    }

    /// A–Z by the first letter of the name, and everything else under #.
    private var sections: [LetterSection] {
        let grouped = Dictionary(grouping: visible) { contact -> String in
            guard let first = contact.displayName.trimmingCharacters(in: .whitespaces).first,
                first.isLetter
            else { return "#" }
            return String(first).folding(options: .diacriticInsensitive, locale: nil).uppercased()
        }

        return grouped.keys
            .sorted { lhs, rhs in
                if lhs == "#" { return false }
                if rhs == "#" { return true }
                return lhs < rhs
            }
            .map { LetterSection(letter: $0, contacts: grouped[$0] ?? []) }
    }
}

/// One person in the list: avatar, name, and their first address or company.
struct ContactRow: View {
    let contact: Contact
    let service: ContactsService

    var body: some View {
        HStack(spacing: 12) {
            ContactAvatar(contact: contact, size: 36, service: service)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: contact.displayName.isEmpty ? (contact.primaryEmail?.email ?? "") : contact.displayName)
                    .font(.body)
                    .lineLimit(1)
                if let detail = contact.primaryEmail?.email ?? contact.company, detail.isEmpty == false {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Initials on a colour picked from the name, so one person is always the
/// same colour.
struct ContactAvatar: View {
    let contact: Contact
    let size: CGFloat
    /// For the photo, when the contact has one.
    var service: ContactsService? = nil

    @State private var photo: UIImage?

    var body: some View {
        let hue = Double(abs(contact.displayName.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % 360) / 360

        Group {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(verbatim: contact.initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color(hue: hue, saturation: 0.45, brightness: 0.7)))
            }
        }
        .accessibilityHidden(true)
        .task(id: contact.photoURL) {
            guard let service, contact.photoURL != nil,
                let data = await service.photo(for: contact)
            else { return }
            photo = UIImage(data: data)?.preparingThumbnail(
                of: CGSize(width: size * 3, height: size * 3))
        }
    }
}

#endif
