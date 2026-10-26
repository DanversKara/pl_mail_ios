#if os(iOS)

public import PLMailCore
import JMAPKit
import SwiftUI

/// BearerMail: the notes wall — the iOS twin of the Android app's Notes
/// screen.
///
/// Pinned notes first, then the rest, as coloured cards in two staggered
/// columns the way Keep and the web draw them. A switch at the top moves
/// between Notes, Archive and Bin; search narrows whichever is showing; the
/// + button starts a new note.
///
/// Carries no `NavigationStack` of its own, like `CalendarView`, so the
/// phone can push it from the sidebar and the iPad can wrap it in a cover.
public struct NotesView: View {
    let service: NotesService
    /// The way out on a presentation that has no back button of its own.
    let close: (() -> Void)?

    @State private var shelf: Shelf = .notes
    @State private var query = ""
    @State private var editing: EditorTarget?
    @State private var labelFilter: String?

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    public init(service: NotesService, close: (() -> Void)? = nil) {
        self.service = service
        self.close = close
    }

    enum Shelf: Hashable, CaseIterable {
        case notes, archive, bin
    }

    /// Which note the editor is open on. A new note has no id until the
    /// server has stored it, so it gets its own case.
    enum EditorTarget: Identifiable, Hashable {
        case new
        case existing(String)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let id): id
            }
        }
    }

    public var body: some View {
        let palette = theme.palette(for: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                shelfPicker
                labelBar
                content
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 96)
        }
        .background(palette.surface.color)
        .navigationTitle(Text(.ui("Notes")))
        .searchable(text: $query, prompt: Text(.ui("Search notes")))
        .refreshable { await service.refresh() }
        .overlay(alignment: .bottomTrailing) { newNoteButton }
        .toolbar {
            if let close {
                ToolbarItem(placement: .topBarLeading) {
                    Button(.ui("Close"), systemImage: "xmark", action: close)
                }
            }
            if shelf == .bin, visible.isEmpty == false {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        Task { await service.emptyBin() }
                    } label: {
                        Label { Text(.ui("Empty bin")) } icon: { Image(systemName: "trash.slash") }
                    }
                }
            }
        }
        .sheet(item: $editing) { target in
            NavigationStack {
                NoteEditorView(service: service, noteID: target.existingID)
            }
            .themedSheet(theme, reduceMotion: false)
        }
        .task {
            if service.notes.isEmpty { await service.load() }
        }
    }

    // MARK: - Pieces

    private var shelfPicker: some View {
        Picker(selection: $shelf) {
            Text(.ui("Notes")).tag(Shelf.notes)
            Text(.ui("Archive")).tag(Shelf.archive)
            Text(.ui("Bin")).tag(Shelf.bin)
        } label: {
            Text(.ui("Show"))
        }
        .pickerStyle(.segmented)
        .padding(.top, 8)
    }

    /// The labels in use, as chips that filter the wall. Hidden when there
    /// are none, so a user who never labels anything never sees an empty row.
    @ViewBuilder
    private var labelBar: some View {
        let labels = Note.labels(in: service.notes.filter { $0.trashed == false })

        if labels.isEmpty == false {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(labels, id: \.self) { label in
                        let isOn = labelFilter == label
                        Button {
                            labelFilter = isOn ? nil : label
                        } label: {
                            Label {
                                Text(verbatim: label)
                            } icon: {
                                Image(systemName: "tag")
                            }
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
    }

    @ViewBuilder
    private var content: some View {
        if service.isAvailable == false && service.isLoading == false && service.notes.isEmpty {
            ContentUnavailableView(
                .ui("This server does not have notes"),
                systemImage: "note.text",
                description: Text(.ui("Notes need a BearerMail server with notes turned on.")))
                .padding(.top, 60)
        } else if visible.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: shelf == .bin ? "trash" : "note.text",
                description: Text(emptyDescription))
                .padding(.top, 60)
        } else {
            let pinned = visible.filter(\.pinned)
            let others = visible.filter { $0.pinned == false }

            if shelf == .notes, pinned.isEmpty == false {
                sectionHeader(.ui("Pinned"))
                masonry(pinned)
                if others.isEmpty == false {
                    sectionHeader(.ui("Others"))
                }
            }
            masonry(shelf == .notes ? others : visible)
        }
    }

    private var emptyTitle: LocalizedStringResource {
        if query.isEmpty == false || labelFilter != nil { return .ui("No matching notes") }
        switch shelf {
        case .notes: return .ui("No notes yet")
        case .archive: return .ui("No archived notes")
        case .bin: return .ui("The bin is empty")
        }
    }

    private var emptyDescription: LocalizedStringResource {
        switch shelf {
        case .notes: .ui("Tap + to write one. Notes sync with BearerMail on the web.")
        case .archive: .ui("Archived notes are kept here, out of the way.")
        case .bin: .ui("Notes you delete wait here until you empty the bin.")
        }
    }

    private func sectionHeader(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(theme.palette(for: colorScheme).inkMuted.color)
            .padding(.leading, 4)
    }

    /// Two columns, filled alternately — the staggered wall without a custom
    /// layout. Order reads left-right, top-bottom like the web's.
    private func masonry(_ notes: [Note]) -> some View {
        let left = notes.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let right = notes.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)

        return HStack(alignment: .top, spacing: 10) {
            column(left)
            column(right)
        }
    }

    private func column(_ notes: [Note]) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(notes) { note in
                NoteCard(note: note)
                    .onTapGesture { editing = .existing(note.id) }
                    .contextMenu { menu(for: note) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func menu(for note: Note) -> some View {
        if note.trashed {
            Button(.ui("Restore"), systemImage: "arrow.uturn.backward") {
                Task { await service.update(note.id, NotePatch(trashed: false)) }
            }
            Button(role: .destructive) {
                Task { await service.destroy(note.id) }
            } label: {
                Label { Text(.ui("Delete forever")) } icon: { Image(systemName: "trash.slash") }
            }
        } else {
            Button(
                note.pinned ? LocalizedStringResource.ui("Unpin") : .ui("Pin"),
                systemImage: note.pinned ? "pin.slash" : "pin"
            ) {
                Task { await service.update(note.id, NotePatch(pinned: !note.pinned)) }
            }
            Button(
                note.archived ? LocalizedStringResource.ui("Unarchive") : .ui("Archive"),
                systemImage: note.archived ? "tray.and.arrow.up" : "archivebox"
            ) {
                Task { await service.update(note.id, NotePatch(archived: !note.archived)) }
            }
            Button(role: .destructive) {
                Task { await service.update(note.id, NotePatch(trashed: true)) }
            } label: {
                Label { Text(.ui("Delete")) } icon: { Image(systemName: "trash") }
            }
        }
    }

    @ViewBuilder
    private var newNoteButton: some View {
        if service.isAvailable, shelf == .notes {
            Button {
                editing = .new
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.palette(for: colorScheme).accentInk.color)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(.themeAccent))
                    .shadow(radius: 4, y: 2)
            }
            .accessibilityLabel(Text(.ui("New note")))
            .padding(20)
        }
    }

    // MARK: - Filtering

    private var visible: [Note] {
        service.notes
            .filter { note in
                switch shelf {
                case .notes: note.trashed == false && note.archived == false
                case .archive: note.trashed == false && note.archived
                case .bin: note.trashed
                }
            }
            .filter { labelFilter == nil || $0.labels.contains(labelFilter ?? "") }
            .filter { $0.matches(query) }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }
}

extension NotesView.EditorTarget {
    var existingID: String? {
        if case .existing(let id) = self { return id }
        return nil
    }
}

/// One note on the wall: its colour, title, the start of its text or
/// checklist, and its labels.
struct NoteCard: View {
    let note: Note

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = theme.palette(for: colorScheme)
        let fill = NoteColors.fill(note.color, scheme: colorScheme) ?? palette.raised.color
        let ink = NoteColors.ink(note.color, scheme: colorScheme) ?? palette.ink.color

        VStack(alignment: .leading, spacing: 8) {
            if note.title.isEmpty == false {
                Text(verbatim: note.title)
                    .font(.headline)
                    .lineLimit(3)
            }

            if note.items.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(note.items.prefix(6).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: item.done ? "checkmark.square" : "square")
                                .font(.caption)
                            Text(verbatim: item.text)
                                .font(.subheadline)
                                .strikethrough(item.done)
                                .opacity(item.done ? 0.6 : 1)
                                .lineLimit(2)
                        }
                    }
                    if note.items.count > 6 {
                        Text(verbatim: "…")
                            .font(.subheadline)
                    }
                }
            } else if note.body.isEmpty == false {
                Text(verbatim: note.body)
                    .font(.subheadline)
                    .lineLimit(10)
            }

            if note.title.isEmpty && note.body.isEmpty && note.items.isEmpty {
                Text(.ui("Empty note"))
                    .font(.subheadline)
                    .italic()
                    .opacity(0.6)
            }

            if note.labels.isEmpty == false || note.reminderAt != nil || note.media.isEmpty == false
            {
                HStack(spacing: 6) {
                    if note.reminderAt != nil {
                        Image(systemName: "bell")
                    }
                    if note.media.isEmpty == false {
                        Image(systemName: note.media.contains(where: \.isAudio) ? "waveform" : "photo")
                    }
                    ForEach(note.labels.prefix(3), id: \.self) { label in
                        Text(verbatim: label)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(ink.opacity(0.1)))
                    }
                }
                .font(.caption2)
            }
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.line.color, lineWidth: note.color == nil ? 1 : 0)
        )
        .overlay(alignment: .topTrailing) {
            if note.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(ink.opacity(0.6))
                    .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

#endif
