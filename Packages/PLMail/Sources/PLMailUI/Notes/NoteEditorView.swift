#if os(iOS)

public import PLMailCore
import JMAPKit
import PhotosUI
import QuickLook
import SwiftUI

/// BearerMail: one note, open for writing — the iOS twin of the Android
/// app's note editor.
///
/// It saves by itself: a moment after you stop typing, and again when the
/// editor closes, so there is no Save button to forget. A new note only
/// reaches the server once something has been written in it, so opening the
/// editor and backing out leaves nothing behind.
struct NoteEditorView: View {
    let service: NotesService

    @State private var noteID: String?
    @State private var title = ""
    @State private var text = ""
    @State private var items: [NoteItem] = []
    @State private var isChecklist = false
    @State private var color: String?
    @State private var pinned = false
    @State private var archived = false
    @State private var trashed = false
    @State private var labels: [String] = []
    @State private var reminder: Date?
    @State private var newLabel = ""
    @State private var isEditingReminder = false
    @State private var isAddingLabel = false
    /// BearerMail: pictures on the note.
    @State private var isPickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var isAddingMedia = false
    @State private var previewURL: URL?
    @State private var hasLoaded = false
    /// What was last sent, so an unchanged editor sends nothing.
    @State private var saved: Snapshot?

    @FocusState private var focusedItem: Int?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    init(service: NotesService, noteID: String?) {
        self.service = service
        _noteID = State(initialValue: noteID)
    }

    /// Everything the editor can change, compared to decide whether a save
    /// has anything to say.
    struct Snapshot: Hashable {
        var title: String
        var text: String
        var items: [NoteItem]
        var color: String?
        var pinned: Bool
        var archived: Bool
        var labels: [String]
        var reminder: Date?
    }

    private var snapshot: Snapshot {
        Snapshot(
            title: title, text: text, items: isChecklist ? items : [], color: color,
            pinned: pinned, archived: archived, labels: labels, reminder: reminder)
    }

    var body: some View {
        let palette = theme.palette(for: colorScheme)
        let fill = NoteColors.fill(color, scheme: colorScheme) ?? palette.raised.color
        let ink = NoteColors.ink(color, scheme: colorScheme) ?? palette.ink.color

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField(text: $title, axis: .vertical) {
                    Text(.ui("Title"))
                }
                .font(.title3.weight(.semibold))
                .disabled(trashed)

                if isChecklist {
                    checklist
                } else {
                    TextField(text: $text, axis: .vertical) {
                        Text(.ui("Note"))
                    }
                    .lineLimit(5...)
                    .disabled(trashed)
                }

                if labels.isEmpty == false || reminder != nil {
                    chips(ink: ink)
                }

                mediaSection(ink: ink)
            }
            .padding(16)
            .foregroundStyle(ink)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(fill.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $isEditingReminder) { reminderSheet }
        .photosPicker(
            isPresented: $isPickingPhotos, selection: $pickedPhotos, maxSelectionCount: 6,
            matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            guard items.isEmpty == false else { return }
            Task { await addPhotos(items) }
        }
        .quickLookPreview($previewURL)
        .alert(Text(.ui("New label")), isPresented: $isAddingLabel) {
            TextField(text: $newLabel) {
                Text(.ui("Label"))
            }
            Button(.ui("Add label"), action: addLabel)
            Button(.ui("Cancel"), role: .cancel) { newLabel = "" }
        }
        .onAppear(perform: load)
        // Autosave: a pause in typing is the moment to send.
        .task(id: snapshot) {
            guard hasLoaded else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard Task.isCancelled == false else { return }
            await save()
        }
        .onDisappear {
            Task { await save() }
        }
    }

    // MARK: - Checklist

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    Button {
                        items[index].done.toggle()
                    } label: {
                        Image(systemName: items[index].done ? "checkmark.square.fill" : "square")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        Text(items[index].done ? LocalizedStringResource.ui("Mark not done") : .ui("Mark done")))

                    TextField(text: $items[index].text, axis: .vertical) {
                        Text(.ui("List item"))
                    }
                    .strikethrough(items[index].done)
                    .focused($focusedItem, equals: index)
                    .onSubmit { addItem(after: index) }

                    Button {
                        items.remove(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(.ui("Remove item")))
                }
                .disabled(trashed)
            }

            if trashed == false {
                Button {
                    addItem(after: items.count - 1)
                } label: {
                    Label {
                        Text(.ui("Add item"))
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(.plain)
                .opacity(0.7)
            }
        }
    }

    private func addItem(after index: Int) {
        let position = min(max(index + 1, 0), items.count)
        items.insert(NoteItem(), at: position)
        focusedItem = position
    }

    // MARK: - Pictures and recordings

    @ViewBuilder
    private func mediaSection(ink: Color) -> some View {
        if let noteID, let note = service.note(id: noteID), note.media.isEmpty == false || isAddingMedia {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(note.media) { media in
                    NoteMediaTile(service: service, noteID: noteID, media: media, ink: ink)
                        .onTapGesture { Task { await open(media, noteID: noteID) } }
                        .contextMenu {
                            if trashed == false {
                                Button(role: .destructive) {
                                    Task { await service.deleteMedia(noteID: noteID, mediaID: media.id) }
                                } label: {
                                    Label {
                                        Text(.ui("Remove"))
                                    } icon: {
                                        Image(systemName: "trash")
                                    }
                                }
                            }
                        }
                }
                if isAddingMedia {
                    ProgressView()
                        .frame(height: 96)
                }
            }
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        pickedPhotos = []
        guard let noteID else { return }
        isAddingMedia = true
        defer { isAddingMedia = false }

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            await service.addMedia(
                noteID: noteID, data: data, type: type?.preferredMIMEType ?? "image/jpeg",
                name: "picture.\(ext)")
        }
    }

    /// Opens a picture or a recording in Quick Look, which plays audio too.
    private func open(_ media: NoteMedia, noteID: String) async {
        guard let data = await service.mediaData(noteID: noteID, media: media) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "note-\(media.id)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = media.name.isEmpty ? (media.isAudio ? "recording.m4a" : "picture.jpg") : media.name
        let url = directory.appending(path: name.replacingOccurrences(of: "/", with: "-"))
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        previewURL = url
    }

    // MARK: - Labels and reminder

    private func chips(ink: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let reminder {
                    Button {
                        isEditingReminder = true
                    } label: {
                        Label {
                            Text(reminder, format: .dateTime.month().day().hour().minute())
                        } icon: {
                            Image(systemName: "bell")
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(ink.opacity(0.1)))
                }
                ForEach(labels, id: \.self) { label in
                    HStack(spacing: 4) {
                        Text(verbatim: label)
                        if trashed == false {
                            Button {
                                labels.removeAll { $0 == label }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(.ui("Remove label")))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(ink.opacity(0.1)))
                }
            }
            .font(.caption)
        }
    }

    private var reminderSheet: some View {
        NavigationStack {
            Form {
                DatePicker(
                    selection: Binding(
                        get: { reminder ?? Date().addingTimeInterval(3600) },
                        set: { reminder = $0 }),
                    in: Date()...
                ) {
                    Text(.ui("Remind me"))
                }
                .datePickerStyle(.graphical)

                if reminder != nil {
                    Button(role: .destructive) {
                        reminder = nil
                        isEditingReminder = false
                    } label: {
                        Text(.ui("Remove reminder"))
                    }
                }
            }
            .navigationTitle(Text(.ui("Reminder")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Done")) {
                        if reminder == nil { reminder = Date().addingTimeInterval(3600) }
                        isEditingReminder = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(.ui("Done")) {
                Task {
                    await save()
                    dismiss()
                }
            }
        }

        if trashed {
            ToolbarItem(placement: .primaryAction) {
                Button(.ui("Restore"), systemImage: "arrow.uturn.backward") {
                    trashed = false
                    Task {
                        if let noteID { await service.update(noteID, NotePatch(trashed: false)) }
                    }
                }
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button(
                    pinned ? LocalizedStringResource.ui("Unpin") : .ui("Pin"),
                    systemImage: pinned ? "pin.fill" : "pin"
                ) {
                    pinned.toggle()
                }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                colorMenu
                Button(.ui("Reminder"), systemImage: reminder == nil ? "bell" : "bell.fill") {
                    isEditingReminder = true
                }
                labelMenu
                if service.supportsMedia {
                    Button(.ui("Add picture"), systemImage: "photo") {
                        Task {
                            // A picture needs a note to hang on: one is made
                            // first when this is a new, unsaved note.
                            if noteID == nil {
                                if title.isEmpty && text.isEmpty { title = String(localized: .ui("Picture")) }
                                await save()
                            }
                            if noteID != nil { isPickingPhotos = true }
                        }
                    }
                }
                Button(
                    isChecklist ? LocalizedStringResource.ui("Plain text") : .ui("Checklist"),
                    systemImage: isChecklist ? "text.alignleft" : "checklist"
                ) {
                    toggleChecklist()
                }
                Spacer()
                Button(
                    archived ? LocalizedStringResource.ui("Unarchive") : .ui("Archive"),
                    systemImage: archived ? "tray.and.arrow.up" : "archivebox"
                ) {
                    archived.toggle()
                }
                Button(role: .destructive) {
                    moveToBin()
                } label: {
                    Label {
                        Text(.ui("Delete"))
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    private var colorMenu: some View {
        Menu {
            Button {
                color = nil
            } label: {
                Label {
                    Text(.ui("Default colour"))
                } icon: {
                    Image(systemName: color == nil ? "checkmark.circle.fill" : "circle")
                }
            }
            ForEach(service.colors, id: \.self) { name in
                Button {
                    color = name
                } label: {
                    Label {
                        Text(Self.colorName(name))
                    } icon: {
                        Image(systemName: color == name ? "checkmark.circle.fill" : "circle.fill")
                            .foregroundStyle(NoteColors.swatch(name))
                    }
                }
            }
        } label: {
            Label {
                Text(.ui("Colour"))
            } icon: {
                Image(systemName: "paintpalette")
            }
        }
    }

    private var labelMenu: some View {
        Menu {
            let known = Note.labels(in: service.notes).filter { labels.contains($0) == false }
            ForEach(known, id: \.self) { label in
                Button {
                    labels.append(label)
                } label: {
                    Text(verbatim: label)
                }
            }
            Section {
                Button {
                    isAddingLabel = true
                } label: {
                    Label {
                        Text(.ui("New label"))
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            }
        } label: {
            Label {
                Text(.ui("Labels"))
            } icon: {
                Image(systemName: "tag")
            }
        }
    }

    private func addLabel() {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        newLabel = ""
        guard label.isEmpty == false, labels.contains(label) == false else { return }
        labels.append(label)
    }

    /// Text becomes one checklist line per line of text, and back — nothing
    /// written is lost by switching.
    private func toggleChecklist() {
        if isChecklist {
            text = items.map(\.text).filter { $0.isEmpty == false }.joined(separator: "\n")
            items = []
            isChecklist = false
        } else {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            items = lines.isEmpty ? [NoteItem()] : lines.map { NoteItem(text: String($0)) }
            text = ""
            isChecklist = true
        }
    }

    private func moveToBin() {
        trashed = true
        Task {
            await save()
            if let noteID { await service.update(noteID, NotePatch(trashed: true)) }
            dismiss()
        }
    }

    // MARK: - Loading and saving

    private func load() {
        guard hasLoaded == false else { return }
        defer { hasLoaded = true }

        guard let noteID, let note = service.note(id: noteID) else {
            saved = snapshot
            return
        }

        title = note.title
        text = note.body
        items = note.items
        isChecklist = note.items.isEmpty == false
        color = note.color
        pinned = note.pinned
        archived = note.archived
        trashed = note.trashed
        labels = note.labels
        reminder = note.reminderAt.flatMap(Self.parse)
        saved = snapshot
    }

    private func save() async {
        let current = snapshot
        guard hasLoaded, trashed == false || noteID == nil, current != saved else { return }

        let cleanItems = current.items.filter {
            $0.text.trimmingCharacters(in: .whitespaces).isEmpty == false
        }

        if let noteID {
            var patch = NotePatch()
            let before = saved
            if current.title != before?.title { patch.title = current.title }
            if current.text != before?.text { patch.body = current.text }
            if current.items != before?.items { patch.items = cleanItems }
            if current.color != before?.color { patch.color = .some(current.color) }
            if current.pinned != before?.pinned { patch.pinned = current.pinned }
            if current.archived != before?.archived { patch.archived = current.archived }
            if current.labels != before?.labels { patch.labels = current.labels }
            if current.reminder != before?.reminder {
                patch.reminderAt = .some(current.reminder.map(Self.format))
            }

            saved = current
            if await service.update(noteID, patch) == false { saved = before }
        } else {
            let draft = NoteDraft(
                title: current.title, body: isChecklist ? "" : current.text, items: cleanItems,
                color: current.color, pinned: current.pinned, archived: current.archived,
                labels: current.labels)
            let probe = Note(
                id: "", title: draft.title, body: draft.body, items: draft.items)
            guard probe.isBlank == false else { return }

            saved = current
            if let created = await service.create(draft) {
                noteID = created.id
                if let reminder = current.reminder {
                    await service.update(
                        created.id, NotePatch(reminderAt: .some(Self.format(reminder))))
                }
            } else {
                saved = nil
            }
        }
    }

    // MARK: - Formatting

    private static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func colorName(_ name: String) -> LocalizedStringResource {
        switch name {
        case "red": .ui("Red")
        case "orange": .ui("Orange")
        case "yellow": .ui("Yellow")
        case "green": .ui("Green")
        case "teal": .ui("Teal")
        case "blue": .ui("Blue")
        case "purple": .ui("Purple")
        case "pink": .ui("Pink")
        case "brown": .ui("Brown")
        case "gray": .ui("Grey")
        default: .ui("Colour")
        }
    }
}

/// One picture, drawing or recording on a note.
struct NoteMediaTile: View {
    let service: NotesService
    let noteID: String
    let media: NoteMedia
    let ink: Color

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ink.opacity(0.08))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: media.isAudio ? "waveform" : "photo")
                    .font(.title2)
                    .foregroundStyle(ink.opacity(0.6))
            }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(Text(media.isAudio ? LocalizedStringResource.ui("Voice note") : .ui("Picture")))
        .task(id: media.id) {
            guard media.isAudio == false,
                let data = await service.mediaData(noteID: noteID, media: media)
            else { return }
            image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 300, height: 300))
        }
    }
}

#endif
