import Foundation
public import JMAPKit
import OSLog
import Observation

/// BearerMail: Drive, for the screens.
///
/// Holds whether the server has Drive, and a small cache of image thumbnails
/// so scrolling a folder of photos does not download each one twice. The
/// folders themselves are read fresh by each screen through ``client``.
@MainActor
@Observable
public final class DriveService {
    public private(set) var isAvailable = false
    /// Bytes used and the quota, from the last listing read.
    public private(set) var usedBytes = 0
    public private(set) var quotaBytes: Int?

    public let client: DriveClient

    /// Downloaded image bytes by file id. Capped so a large photo folder
    /// cannot hold the whole library in memory.
    private var thumbnails: [Int: Data] = [:]
    private var thumbnailOrder: [Int] = []
    private static let thumbnailLimit = 120
    private let logger = Logger(subsystem: "de.plmail", category: "drive")

    public init(client: JMAPClient) {
        self.client = DriveClient(client: client)
    }

    public func load() async {
        isAvailable = await client.isAvailable()
    }

    public func list(folderID: Int?) async throws -> DriveListing {
        let listing = try await client.list(folderID: folderID)
        usedBytes = listing.usedBytes
        quotaBytes = listing.quotaBytes
        return listing
    }

    /// The bytes of an image file, from the cache when they are there.
    public func imageData(for file: DriveFile) async -> Data? {
        if let cached = thumbnails[file.id] { return cached }
        // Very large images are not worth a thumbnail download.
        guard file.isImage, file.size < 15_000_000 else { return nil }

        do {
            let data = try await client.download(file.id)
            thumbnails[file.id] = data
            thumbnailOrder.append(file.id)
            if thumbnailOrder.count > Self.thumbnailLimit {
                thumbnails[thumbnailOrder.removeFirst()] = nil
            }
            return data
        } catch {
            logger.debug("Thumbnail download failed")
            return nil
        }
    }

    /// Downloads a file into a temporary folder under its own name, for
    /// Quick Look or the share sheet. The folder is per file id, so two files
    /// with the same name do not overwrite each other.
    public func temporaryCopy(of file: DriveFile) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "drive-\(file.id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = file.name.replacingOccurrences(of: "/", with: "-")
        let url = directory.appending(path: safeName.isEmpty ? "file" : safeName)

        let data: Data
        if let cached = thumbnails[file.id] {
            data = cached
        } else {
            data = try await client.download(file.id)
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
