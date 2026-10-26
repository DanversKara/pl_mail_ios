#if os(iOS)

public import PLMailCore
import JMAPKit
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// BearerMail: Drive — the iOS twin of the Android app's Drive screen.
///
/// The top folder; each folder pushes the next. Folders first, then files as
/// tiles — pictures show themselves, everything else its kind of icon. Tap a
/// file to open it in Quick Look; hold it to share a link, rename or delete.
/// The + menu uploads photos or files and makes folders.
public struct DriveView: View {
    let service: DriveService
    let close: (() -> Void)?

    public init(service: DriveService, close: (() -> Void)? = nil) {
        self.service = service
        self.close = close
    }

    public var body: some View {
        DriveFolderView(service: service, folderID: nil, title: nil)
            .toolbar {
                if let close {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(.ui("Close"), systemImage: "xmark", action: close)
                    }
                }
            }
            .task {
                if service.isAvailable == false { await service.load() }
            }
    }
}

struct DriveFolderView: View {
    let service: DriveService
    let folderID: Int?
    let title: String?

    @State private var listing: DriveListing?
    @State private var failure: String?
    @State private var isWorking = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isImportingFiles = false
    @State private var isNamingFolder = false
    @State private var folderName = ""
    @State private var renaming: Rename?
    @State private var renameText = ""
    @State private var previewURL: URL?
    @State private var copiedLink = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// What the rename prompt is renaming.
    enum Rename: Identifiable, Hashable {
        case file(DriveFile)
        case folder(DriveFolder)

        var id: String {
            switch self {
            case .file(let file): "f\(file.id)"
            case .folder(let folder): "d\(folder.id)"
            }
        }

        var currentName: String {
            switch self {
            case .file(let file): file.name
            case .folder(let folder): folder.name
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12)]

    var body: some View {
        let palette = theme.palette(for: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if folderID == nil, let listing { usage(listing) }

                if let failure {
                    Text(verbatim: failure)
                        .foregroundStyle(palette.danger.color)
                        .font(.footnote)
                }

                if let listing {
                    if listing.folders.isEmpty && listing.files.isEmpty {
                        ContentUnavailableView(
                            .ui("This folder is empty"),
                            systemImage: "folder",
                            description: Text(.ui("Tap + to upload photos or files.")))
                            .padding(.top, 40)
                    }

                    if listing.folders.isEmpty == false {
                        VStack(spacing: 0) {
                            ForEach(listing.folders) { folder in
                                NavigationLink {
                                    DriveFolderView(
                                        service: service, folderID: folder.id, title: folder.name)
                                } label: {
                                    folderRow(folder)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { folderMenu(folder) }
                                Divider()
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 12).fill(palette.raised.color))
                    }

                    if listing.files.isEmpty == false {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(listing.files) { file in
                                Button {
                                    Task { await open(file) }
                                } label: {
                                    DriveFileTile(service: service, file: file)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { fileMenu(file) }
                            }
                        }
                    }
                } else if service.isAvailable == false && isWorking == false {
                    ContentUnavailableView(
                        .ui("This server does not have Drive"),
                        systemImage: "externaldrive",
                        description: Text(.ui("Drive needs a BearerMail server with Drive turned on.")))
                        .padding(.top, 40)
                }
            }
            .padding(12)
        }
        .background(palette.surface.color)
        .navigationTitle(title.map { Text(verbatim: $0) } ?? Text(.ui("Drive")))
        .overlay {
            if isWorking { ProgressView().controlSize(.large) }
        }
        .overlay(alignment: .bottom) {
            if copiedLink {
                Text(.ui("Link copied"))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .refreshable { await reload() }
        .toolbar {
            if service.isAvailable {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isPickingPhotos = true
                        } label: {
                            Label { Text(.ui("Upload photos")) } icon: { Image(systemName: "photo.on.rectangle") }
                        }
                        Button {
                            isImportingFiles = true
                        } label: {
                            Label { Text(.ui("Upload files")) } icon: { Image(systemName: "doc.badge.plus") }
                        }
                        Button {
                            folderName = ""
                            isNamingFolder = true
                        } label: {
                            Label { Text(.ui("New folder")) } icon: { Image(systemName: "folder.badge.plus") }
                        }
                    } label: {
                        Label { Text(.ui("Add")) } icon: { Image(systemName: "plus") }
                    }
                }
            }
        }
        .photosPicker(isPresented: $isPickingPhotos, selection: $photoItems, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard items.isEmpty == false else { return }
            Task { await upload(photos: items) }
        }
        .fileImporter(
            isPresented: $isImportingFiles, allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await upload(files: urls) }
            }
        }
        .alert(Text(.ui("New folder")), isPresented: $isNamingFolder) {
            TextField(text: $folderName) { Text(.ui("Name")) }
            Button(.ui("Create")) { Task { await createFolder() } }
            Button(.ui("Cancel"), role: .cancel) {}
        }
        .alert(
            Text(.ui("Rename")),
            isPresented: Binding(get: { renaming != nil }, set: { if $0 == false { renaming = nil } })
        ) {
            TextField(text: $renameText) { Text(.ui("Name")) }
            Button(.ui("Rename")) { Task { await rename() } }
            Button(.ui("Cancel"), role: .cancel) { renaming = nil }
        }
        .quickLookPreview($previewURL)
        .task(id: folderID) {
            if service.isAvailable == false { await service.load() }
            await reload()
        }
    }

    // MARK: - Pieces

    private func usage(_ listing: DriveListing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quota = listing.quotaBytes, quota > 0 {
                ProgressView(value: min(Double(listing.usedBytes) / Double(quota), 1))
                Text(
                    verbatim: "\(Self.bytes(listing.usedBytes)) / \(Self.bytes(quota))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: Self.bytes(listing.usedBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func folderRow(_ folder: DriveFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.themeAccent)
                .font(.title3)
            Text(verbatim: folder.name)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func folderMenu(_ folder: DriveFolder) -> some View {
        Button {
            renameText = folder.name
            renaming = .folder(folder)
        } label: {
            Label { Text(.ui("Rename")) } icon: { Image(systemName: "pencil") }
        }
        Button(role: .destructive) {
            Task { await perform { try await service.client.deleteFolder(folder.id) } }
        } label: {
            Label { Text(.ui("Delete")) } icon: { Image(systemName: "trash") }
        }
    }

    @ViewBuilder
    private func fileMenu(_ file: DriveFile) -> some View {
        Button {
            Task { await copyLink(for: file) }
        } label: {
            Label { Text(.ui("Copy share link")) } icon: { Image(systemName: "link") }
        }
        Button {
            Task { await open(file) }
        } label: {
            Label { Text(.ui("Open")) } icon: { Image(systemName: "eye") }
        }
        Button {
            renameText = file.name
            renaming = .file(file)
        } label: {
            Label { Text(.ui("Rename")) } icon: { Image(systemName: "pencil") }
        }
        Button(role: .destructive) {
            Task { await perform { try await service.client.deleteFile(file.id) } }
        } label: {
            Label { Text(.ui("Delete")) } icon: { Image(systemName: "trash") }
        }
    }

    // MARK: - Actions

    private func reload() async {
        do {
            listing = try await service.list(folderID: folderID)
            failure = nil
        } catch {
            if service.isAvailable { failure = Self.describe(error) }
        }
    }

    /// Runs a change, then re-reads the folder so the screen shows what the
    /// server now holds.
    private func perform(_ change: @escaping () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await change()
            failure = nil
        } catch {
            failure = Self.describe(error)
        }
        await reload()
    }

    private func open(_ file: DriveFile) async {
        isWorking = true
        defer { isWorking = false }
        do {
            previewURL = try await service.temporaryCopy(of: file)
        } catch {
            failure = Self.describe(error)
        }
    }

    private func copyLink(for file: DriveFile) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let existing = try await service.client.shares(of: file.id)
                .first { $0.isProtected == false && $0.expiresAt == nil }
            let share: DriveShare
            if let existing {
                share = existing
            } else {
                share = try await service.client.createShare(
                    fileID: file.id, password: nil, expires: nil)
            }
            UIPasteboard.general.string = share.url
            withAnimation { copiedLink = true }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copiedLink = false }
        } catch {
            failure = Self.describe(error)
        }
    }

    private func createFolder() async {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        guard name.isEmpty == false else { return }
        await perform { _ = try await service.client.createFolder(name: name, parentID: folderID) }
    }

    private func rename() async {
        guard let target = renaming else { return }
        renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard name.isEmpty == false, name != target.currentName else { return }

        switch target {
        case .file(let file):
            await perform { try await service.client.renameFile(file.id, to: name) }
        case .folder(let folder):
            await perform { try await service.client.renameFolder(folder.id, to: name) }
        }
    }

    private func upload(photos items: [PhotosPickerItem]) async {
        photoItems = []
        await perform {
            for (index, item) in items.enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                let ext = type?.preferredFilenameExtension ?? "jpg"
                let mime = type?.preferredMIMEType ?? "image/jpeg"
                let stamp = Self.stamp.string(from: Date())
                _ = try await service.client.upload(
                    name: "Photo \(stamp)-\(index + 1).\(ext)", type: mime, data: data,
                    folderID: folderID)
            }
        }
    }

    private func upload(files urls: [URL]) async {
        await perform {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                _ = try await service.client.upload(
                    name: url.lastPathComponent, type: mime, data: data, folderID: folderID)
            }
        }
    }

    // MARK: - Formatting

    /// Names uploaded photos by when they arrived, like the web does.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func describe(_ error: any Error) -> String {
        switch error as? DriveError {
        case .tooLarge(let size, let limit):
            return String(
                localized: .ui("This file is too big for Drive."))
                + " (\(bytes(size)) > \(bytes(limit)))"
        case .rejected(_, let detail?):
            return detail
        case .unavailable:
            return String(localized: .ui("This server does not have Drive"))
        default:
            return String(localized: .ui("Drive could not be reached. Pull down to try again."))
        }
    }
}

/// One file as a tile: the picture itself for images, a kind-of-file icon
/// otherwise, and the name underneath.
struct DriveFileTile: View {
    let service: DriveService
    let file: DriveFile

    @State private var image: UIImage?

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = theme.palette(for: colorScheme)

        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.sunken.color)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: Self.symbol(for: file))
                        .font(.system(size: 34))
                        .foregroundStyle(.themeAccent)
                }
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(verbatim: file.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .task(id: file.id) {
            guard file.isImage, let data = await service.imageData(for: file) else { return }
            image = Self.thumbnail(from: data)
        }
        .accessibilityElement(children: .combine)
    }

    /// A small decoded copy, so a grid of 12-megapixel photos does not hold
    /// 12-megapixel bitmaps.
    static func thumbnail(from data: Data) -> UIImage? {
        UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 320, height: 320))
    }

    static func symbol(for file: DriveFile) -> String {
        if file.isImage { return "photo" }
        if file.isPDF { return "doc.richtext" }
        if file.isText { return "doc.text" }
        if file.isAudio { return "waveform" }
        if file.isVideo { return "film" }
        let name = file.name.lowercased()
        if name.hasSuffix(".zip") || name.hasSuffix(".tar") || name.hasSuffix(".gz") {
            return "doc.zipper"
        }
        if name.hasSuffix(".xlsx") || name.hasSuffix(".csv") || name.hasSuffix(".ods") {
            return "tablecells"
        }
        if name.hasSuffix(".docx") || name.hasSuffix(".odt") || name.hasSuffix(".pages") {
            return "doc.text"
        }
        return "doc"
    }
}

#endif
