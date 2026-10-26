import Foundation

// BearerMail: Drive — personal file storage on the user's own server.
//
// Not JMAP: a small JSON API under the Session's
// `urn:bearermail:params:drive` `apiUrl`, signed with the same app password.
// The same endpoints and shapes as the Android app's DriveClient.

public struct DriveFolder: Hashable, Sendable, Decodable, Identifiable {
    public var id: Int
    public var name: String
    public var parentID: Int?

    private enum CodingKeys: String, CodingKey {
        case id, name
        case parentID = "parentId"
    }
}

public struct DriveFile: Hashable, Sendable, Decodable, Identifiable {
    public var id: Int
    public var name: String
    public var type: String
    public var size: Int
    public var folderID: Int?
    public var updatedAt: String
    public var shareCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, type, size, updatedAt, shareCount
        case folderID = "folderId"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "application/octet-stream"
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        folderID = try c.decodeIfPresent(Int.self, forKey: .folderID)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        shareCount = try c.decodeIfPresent(Int.self, forKey: .shareCount) ?? 0
    }

    public var isImage: Bool { type.hasPrefix("image/") }
    public var isPDF: Bool { type == "application/pdf" }
    public var isText: Bool { type.hasPrefix("text/") }
    public var isAudio: Bool { type.hasPrefix("audio/") }
    public var isVideo: Bool { type.hasPrefix("video/") }
}

public struct DriveListing: Sendable, Decodable {
    public var folder: DriveFolder?
    public var breadcrumbs: [DriveFolder]
    public var folders: [DriveFolder]
    public var files: [DriveFile]
    public var usedBytes: Int
    public var quotaBytes: Int?

    private enum CodingKeys: String, CodingKey {
        case folder, breadcrumbs, folders, files, usedBytes, quotaBytes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = try c.decodeIfPresent(DriveFolder.self, forKey: .folder)
        breadcrumbs = try c.decodeIfPresent([DriveFolder].self, forKey: .breadcrumbs) ?? []
        folders = try c.decodeIfPresent([DriveFolder].self, forKey: .folders) ?? []
        files = try c.decodeIfPresent([DriveFile].self, forKey: .files) ?? []
        usedBytes = try c.decodeIfPresent(Int.self, forKey: .usedBytes) ?? 0
        quotaBytes = try c.decodeIfPresent(Int.self, forKey: .quotaBytes)
    }
}

public struct DriveShare: Hashable, Sendable, Decodable, Identifiable {
    public var id: Int
    public var url: String
    public var isProtected: Bool
    public var expiresAt: String?
    public var downloadCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, url, expiresAt, downloadCount
        case isProtected = "protected"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        isProtected = try c.decodeIfPresent(Bool.self, forKey: .isProtected) ?? false
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
        downloadCount = try c.decodeIfPresent(Int.self, forKey: .downloadCount) ?? 0
    }
}

/// Why a Drive call failed, in a form a screen can say.
public enum DriveError: Error, Hashable, Sendable {
    /// The server has no Drive.
    case unavailable
    /// The file is over the server's limit; both sizes in bytes.
    case tooLarge(size: Int, limit: Int)
    /// The server said no. `detail` is its own sentence when it gave one.
    case rejected(status: Int, detail: String?)
    case malformed
}

public struct DriveClient: Sendable {
    private let client: JMAPClient

    public init(client: JMAPClient) {
        self.client = client
    }

    public func isAvailable() async -> Bool {
        (try? await baseURL()) != nil
    }

    public func maxUploadBytes() async -> Int {
        (try? await client.session().capabilities.drive?.maxSizeUpload) ?? 50_000_000
    }

    public func list(folderID: Int?) async throws -> DriveListing {
        try await decode(send("GET", folderID.map { "?folder=\($0)" } ?? ""))
    }

    public func upload(name: String, type: String, data: Data, folderID: Int?) async throws
        -> DriveFile
    {
        let limit = await maxUploadBytes()
        guard data.count <= limit else { throw DriveError.tooLarge(size: data.count, limit: limit) }

        var path = "/upload?name=\(Self.encode(name))"
        if let folderID { path += "&folder=\(folderID)" }

        return try await decode(
            send("POST", path, body: data, type: type.isEmpty ? "application/octet-stream" : type))
    }

    public func createFolder(name: String, parentID: Int?) async throws -> DriveFolder {
        try await decode(sendJSON("POST", "/folder", ["name": .string(name), "parentId": parentID.map { JSONValue.int($0) } ?? JSONValue.null]))
    }

    public func renameFolder(_ id: Int, to name: String) async throws {
        _ = try await sendJSON("PATCH", "/folder/\(id)", ["name": .string(name)])
    }

    public func deleteFolder(_ id: Int) async throws {
        _ = try await send("DELETE", "/folder/\(id)")
    }

    public func renameFile(_ id: Int, to name: String) async throws {
        _ = try await sendJSON("PATCH", "/file/\(id)", ["name": .string(name)])
    }

    public func moveFile(_ id: Int, to folderID: Int?) async throws {
        _ = try await sendJSON(
            "PATCH", "/file/\(id)", ["folderId": folderID.map { JSONValue.int($0) } ?? JSONValue.null])
    }

    public func deleteFile(_ id: Int) async throws {
        _ = try await send("DELETE", "/file/\(id)")
    }

    /// The file's bytes. Drive files are capped by the server, so holding
    /// one in memory is bounded.
    public func download(_ id: Int) async throws -> Data {
        try await send("GET", "/file/\(id)/download", accept: "*/*")
    }

    public func shares(of fileID: Int) async throws -> [DriveShare] {
        struct Shares: Decodable { var shares: [DriveShare] }
        return try await (decode(send("GET", "/file/\(fileID)/shares")) as Shares).shares
    }

    public func createShare(fileID: Int, password: String?, expires: String?) async throws
        -> DriveShare
    {
        var body: [String: JSONValue] = [:]
        if let password, password.isEmpty == false { body["password"] = .string(password) }
        if let expires, expires.isEmpty == false { body["expires"] = .string(expires) }
        return try await decode(sendJSON("POST", "/file/\(fileID)/shares", body))
    }

    public func revokeShare(_ id: Int) async throws {
        _ = try await send("DELETE", "/share/\(id)")
    }

    // MARK: - Plumbing

    /// Just enough JSON for Drive's request bodies.
    public enum JSONValue: Encodable, Sendable {
        case string(String)
        case int(Int)
        case null

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let value): try c.encode(value)
            case .int(let value): try c.encode(value)
            case .null: try c.encodeNil()
            }
        }
    }

    private func baseURL() async throws -> String {
        guard let raw = try await client.session().capabilities.drive?.apiURL,
            raw.isEmpty == false
        else { throw DriveError.unavailable }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    private func sendJSON(_ method: String, _ path: String, _ body: [String: JSONValue])
        async throws -> Data
    {
        try await send(
            method, path, body: try JSONEncoder().encode(body), type: "application/json")
    }

    private func send(
        _ method: String, _ path: String, body: Data? = nil, type: String? = nil,
        accept: String = "application/json"
    ) async throws -> Data {
        guard let url = URL(string: try await baseURL() + path) else {
            throw DriveError.malformed
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }

        let (data, response) = try await client.authorized(request)

        guard (200..<300).contains(response.statusCode) else {
            struct Problem: Decodable { var detail: String? }
            let detail = (try? JSONDecoder().decode(Problem.self, from: data))?.detail
            throw DriveError.rejected(status: response.statusCode, detail: detail)
        }

        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DriveError.malformed
        }
    }

    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
