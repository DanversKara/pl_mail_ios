#if os(iOS)

import JMAPKit
import PLMailCore
import SwiftUI

/// BearerMail: what the composer's Insert menu can put into a message — a
/// note, or a link to a Drive file — the iOS twin of Android's "Insert note"
/// and "Insert file from Drive".

/// Pick a note; its title, text or checklist go into the message as text.
struct InsertNoteSheet: View {
    let onPick: (String) -> Void

    @State private var service: NotesService
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    init(client: JMAPClient, onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        _service = State(wrappedValue: NotesService(client: client))
    }

    var body: some View {
        List {
            ForEach(notes) { note in
                Button {
                    onPick(Self.text(of: note))
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: note.title.isEmpty ? Self.firstLine(of: note) : note.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if note.title.isEmpty == false {
                            Text(verbatim: Self.firstLine(of: note))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .overlay {
            if service.isLoading && service.notes.isEmpty {
                ProgressView()
            } else if notes.isEmpty {
                ContentUnavailableView(
                    .ui("No notes yet"), systemImage: "note.text",
                    description: Text(.ui("Notes you write in BearerMail can be inserted here.")))
            }
        }
        .searchable(text: $query, prompt: Text(.ui("Search notes")))
        .navigationTitle(Text(.ui("Insert note")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(.ui("Cancel")) { dismiss() }
            }
        }
        .task { await service.load() }
    }

    private var notes: [Note] {
        service.notes
            .filter { $0.trashed == false && $0.isBlank == false && $0.matches(query) }
            .sorted { ($0.pinned ? 1 : 0, $0.updatedAt ?? "") > ($1.pinned ? 1 : 0, $1.updatedAt ?? "") }
    }

    static func firstLine(of note: Note) -> String {
        let source = note.items.isEmpty ? note.body : (note.items.first?.text ?? "")
        return source.split(separator: "\n").first.map(String.init) ?? ""
    }

    /// The note as plain text: title, then the text or a ☐/☑ checklist.
    static func text(of note: Note) -> String {
        var lines: [String] = []
        if note.title.isEmpty == false { lines.append(note.title) }
        if note.items.isEmpty {
            if note.body.isEmpty == false { lines.append(note.body) }
        } else {
            lines += note.items.map { ($0.done ? "☑ " : "☐ ") + $0.text }
        }
        return lines.joined(separator: "\n")
    }
}

/// Pick a Drive file; a share link to it goes into the message, so a large
/// file travels as a link instead of an attachment.
struct InsertDriveLinkSheet: View {
    let onPick: (String) -> Void

    @State private var service: DriveService
    @Environment(\.dismiss) private var dismiss

    init(client: JMAPClient, onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        _service = State(wrappedValue: DriveService(client: client))
    }

    var body: some View {
        DriveLinkFolder(service: service, folderID: nil, title: nil) { link in
            onPick(link)
            dismiss()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(.ui("Cancel")) { dismiss() }
            }
        }
        .task { await service.load() }
    }
}

private struct DriveLinkFolder: View {
    let service: DriveService
    let folderID: Int?
    let title: String?
    let onPick: (String) -> Void

    @State private var listing: DriveListing?
    @State private var failure: String?
    @State private var isWorking = false

    var body: some View {
        List {
            if let failure {
                Text(verbatim: failure)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
            if let listing {
                ForEach(listing.folders) { folder in
                    NavigationLink {
                        DriveLinkFolder(
                            service: service, folderID: folder.id, title: folder.name,
                            onPick: onPick)
                    } label: {
                        Label {
                            Text(verbatim: folder.name)
                        } icon: {
                            Image(systemName: "folder.fill")
                        }
                    }
                }
                ForEach(listing.files) { file in
                    Button {
                        Task { await pick(file) }
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(verbatim: file.name)
                                    .foregroundStyle(.primary)
                                Text(verbatim: ByteCountFormatter.string(
                                    fromByteCount: Int64(file.size), countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: DriveFileTile.symbol(for: file))
                        }
                    }
                    .disabled(isWorking)
                }
            }
        }
        .overlay {
            if isWorking || listing == nil && failure == nil { ProgressView() }
        }
        .navigationTitle(title.map { Text(verbatim: $0) } ?? Text(.ui("Insert Drive link")))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: folderID) {
            do {
                listing = try await service.list(folderID: folderID)
            } catch {
                failure = DriveFolderView.describe(error)
            }
        }
    }

    /// Reuses an open link when the file has one, so inserting the same file
    /// twice does not pile up links.
    private func pick(_ file: DriveFile) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let open = try await service.client.shares(of: file.id)
                .first { $0.isProtected == false && $0.expiresAt == nil }
            let share: DriveShare
            if let open {
                share = open
            } else {
                share = try await service.client.createShare(
                    fileID: file.id, password: nil, expires: nil)
            }
            onPick("\(file.name): \(share.url)")
        } catch {
            failure = DriveFolderView.describe(error)
        }
    }
}

#endif
