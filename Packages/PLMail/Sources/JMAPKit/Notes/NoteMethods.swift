import Foundation

// BearerMail: Keep-style notes — `Note/get` and `Note/set` under
// `urn:plmail:params:jmap:notes`.
//
// The same wire shapes the Android app speaks (core/jmap NoteMethods.kt), so a
// note written on either phone or on the web is the same note everywhere.
// Notes are per user, like appearance: neither method takes an `accountId`, and
// the server refuses one if sent.

/// One line of a checklist.
public struct NoteItem: Hashable, Sendable, Codable {
    public var text: String
    public var done: Bool

    public init(text: String = "", done: Bool = false) {
        self.text = text
        self.done = done
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }

    private enum CodingKeys: String, CodingKey { case text, done }
}

/// Something a note points at: an event, a file, a contact or a mail.
public struct NoteLink: Hashable, Sendable, Codable {
    public static let event = "event"
    public static let file = "file"
    public static let contact = "contact"
    public static let mail = "mail"

    public var type: String
    public var id: String
    public var title: String?

    public init(type: String, id: String, title: String? = nil) {
        self.type = type
        self.id = id
        self.title = title
    }

    /// Written by hand so a link without a title still sends `"title": null`,
    /// which is what the server and the Android app write.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
    }

    private enum CodingKeys: String, CodingKey { case type, id, title }
}

/// A picture, drawing or voice recording attached to a note.
public struct NoteMedia: Hashable, Sendable, Decodable, Identifiable {
    public static let image = "image"
    public static let drawing = "drawing"
    public static let audio = "audio"

    public var id: String
    public var kind: String
    public var name: String
    public var type: String
    public var size: Int

    public var isAudio: Bool { kind == Self.audio }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? Self.image
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        type =
            try container.decodeIfPresent(String.self, forKey: .type)
            ?? "application/octet-stream"
        size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, type, size }
}

/// One note as the server holds it.
///
/// Decoded leniently: every property but `id` falls back to its empty value,
/// so a server that leaves one out (an older one has no `labels` or `media`)
/// still gives a usable note rather than an unreadable list.
public struct Note: Hashable, Sendable, Decodable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var items: [NoteItem]
    /// One of the server's colour names, or nil for the default card.
    public var color: String?
    public var pinned: Bool
    public var archived: Bool
    public var trashed: Bool
    public var links: [NoteLink]
    public var labels: [String]
    /// ISO 8601, UTC. Nil when no reminder is set.
    public var reminderAt: String?
    public var reminderSent: Bool
    public var media: [NoteMedia]
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        id: String, title: String = "", body: String = "", items: [NoteItem] = [],
        color: String? = nil, pinned: Bool = false, archived: Bool = false,
        trashed: Bool = false, links: [NoteLink] = [], labels: [String] = [],
        reminderAt: String? = nil, reminderSent: Bool = false, media: [NoteMedia] = [],
        createdAt: String? = nil, updatedAt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.items = items
        self.color = color
        self.pinned = pinned
        self.archived = archived
        self.trashed = trashed
        self.links = links
        self.labels = labels
        self.reminderAt = reminderAt
        self.reminderSent = reminderSent
        self.media = media
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        items = try c.decodeIfPresent([NoteItem].self, forKey: .items) ?? []
        color = try c.decodeIfPresent(String.self, forKey: .color)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        trashed = try c.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        links = try c.decodeIfPresent([NoteLink].self, forKey: .links) ?? []
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        reminderAt = try c.decodeIfPresent(String.self, forKey: .reminderAt)
        reminderSent = try c.decodeIfPresent(Bool.self, forKey: .reminderSent) ?? false
        media = try c.decodeIfPresent([NoteMedia].self, forKey: .media) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, items, color, pinned, archived, trashed, links, labels
        case reminderAt, reminderSent, media, createdAt, updatedAt
    }

    /// Nothing written yet: no title, no text, no checklist line with words in it.
    public var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && items.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            && media.isEmpty
    }
}

// MARK: - Note/get

public struct NoteGet: JMAPMethod {
    public static let name = "Note/get"
    public static let capability = Capability.notes

    public struct Arguments: Encodable, Sendable {
        /// Nil asks for every note, and is written as an explicit `null`.
        public var ids: [String]?

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: JMAPCodingKey.self)
            try container.encode(ids, forKey: JMAPCodingKey("ids"))
        }
    }

    public struct Result: Decodable, Sendable {
        public var state: StateToken
        public var list: [Note]
        public var notFound: [String]

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: JMAPCodingKey.self)
            state = try c.decode(StateToken.self, forKey: JMAPCodingKey("state"))
            list = try c.decodeIfPresent([Note].self, forKey: JMAPCodingKey("list")) ?? []
            notFound =
                try c.decodeIfPresent([String].self, forKey: JMAPCodingKey("notFound")) ?? []
        }
    }

    public var arguments: Arguments

    public init(ids: [String]? = nil) {
        arguments = Arguments(ids: ids)
    }
}

// MARK: - Note/set

/// A change to one note, carrying only the properties being changed.
///
/// `nil` means "not mentioned". Colour and reminder can also be cleared, so
/// those two are double optionals: `.some(nil)` writes an explicit `null`.
public struct NotePatch: Encodable, Sendable, Hashable {
    public var title: String?
    public var body: String?
    public var items: [NoteItem]?
    public var color: String??
    public var pinned: Bool?
    public var archived: Bool?
    public var trashed: Bool?
    public var links: [NoteLink]?
    public var labels: [String]?
    public var reminderAt: String??

    public init(
        title: String? = nil, body: String? = nil, items: [NoteItem]? = nil,
        color: String?? = nil, pinned: Bool? = nil, archived: Bool? = nil,
        trashed: Bool? = nil, links: [NoteLink]? = nil, labels: [String]? = nil,
        reminderAt: String?? = nil
    ) {
        self.title = title
        self.body = body
        self.items = items
        self.color = color
        self.pinned = pinned
        self.archived = archived
        self.trashed = trashed
        self.links = links
        self.labels = labels
        self.reminderAt = reminderAt
    }

    public var isEmpty: Bool { self == NotePatch() }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: JMAPCodingKey.self)
        if let title { try c.encode(title, forKey: JMAPCodingKey("title")) }
        if let body { try c.encode(body, forKey: JMAPCodingKey("body")) }
        if let items { try c.encode(items, forKey: JMAPCodingKey("items")) }
        if let color { try c.encode(color, forKey: JMAPCodingKey("color")) }
        if let pinned { try c.encode(pinned, forKey: JMAPCodingKey("pinned")) }
        if let archived { try c.encode(archived, forKey: JMAPCodingKey("archived")) }
        if let trashed { try c.encode(trashed, forKey: JMAPCodingKey("trashed")) }
        if let links { try c.encode(links, forKey: JMAPCodingKey("links")) }
        if let labels { try c.encode(labels, forKey: JMAPCodingKey("labels")) }
        if let reminderAt { try c.encode(reminderAt, forKey: JMAPCodingKey("reminderAt")) }
    }
}

/// A new note. Labels are only sent when there are some: a server from before
/// labels refuses the property outright.
public struct NoteDraft: Encodable, Sendable, Hashable {
    public var title: String
    public var body: String
    public var items: [NoteItem]
    public var color: String?
    public var pinned: Bool
    public var archived: Bool
    public var links: [NoteLink]
    public var labels: [String]

    public init(
        title: String = "", body: String = "", items: [NoteItem] = [], color: String? = nil,
        pinned: Bool = false, archived: Bool = false, links: [NoteLink] = [],
        labels: [String] = []
    ) {
        self.title = title
        self.body = body
        self.items = items
        self.color = color
        self.pinned = pinned
        self.archived = archived
        self.links = links
        self.labels = labels
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: JMAPCodingKey.self)
        try c.encode(title, forKey: JMAPCodingKey("title"))
        try c.encode(body, forKey: JMAPCodingKey("body"))
        try c.encode(items, forKey: JMAPCodingKey("items"))
        try c.encode(color, forKey: JMAPCodingKey("color"))
        try c.encode(pinned, forKey: JMAPCodingKey("pinned"))
        try c.encode(archived, forKey: JMAPCodingKey("archived"))
        try c.encode(links, forKey: JMAPCodingKey("links"))
        if labels.isEmpty == false { try c.encode(labels, forKey: JMAPCodingKey("labels")) }
    }
}

public struct NoteSetError: Hashable, Sendable, Decodable {
    public var type: MethodErrorType
    /// The server's own sentence, for diagnostics only.
    public var description: String?
    public var properties: [String]?
}

public struct NoteSet: JMAPMethod {
    public static let name = "Note/set"
    public static let capability = Capability.notes

    public struct Arguments: Encodable, Sendable {
        public var create: [String: NoteDraft]
        public var update: [String: NotePatch]
        public var destroy: [String]
        public var ifInState: StateToken?

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: JMAPCodingKey.self)
            if let ifInState { try c.encode(ifInState, forKey: JMAPCodingKey("ifInState")) }
            if create.isEmpty == false { try c.encode(create, forKey: JMAPCodingKey("create")) }
            if update.isEmpty == false { try c.encode(update, forKey: JMAPCodingKey("update")) }
            if destroy.isEmpty == false {
                try c.encode(destroy, forKey: JMAPCodingKey("destroy"))
            }
        }
    }

    public struct Result: Decodable, Sendable {
        public var newState: StateToken?
        public var created: [String: Note]
        public var notCreated: [String: NoteSetError]
        public var updated: [String: Note?]
        public var notUpdated: [String: NoteSetError]
        public var destroyed: [String]
        public var notDestroyed: [String: NoteSetError]

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: JMAPCodingKey.self)
            newState = try c.decodeIfPresent(StateToken.self, forKey: JMAPCodingKey("newState"))
            created =
                try c.decodeIfPresent([String: Note].self, forKey: JMAPCodingKey("created")) ?? [:]
            notCreated =
                try c.decodeIfPresent(
                    [String: NoteSetError].self, forKey: JMAPCodingKey("notCreated")) ?? [:]
            updated =
                try c.decodeIfPresent([String: Note?].self, forKey: JMAPCodingKey("updated"))
                ?? [:]
            notUpdated =
                try c.decodeIfPresent(
                    [String: NoteSetError].self, forKey: JMAPCodingKey("notUpdated")) ?? [:]
            destroyed =
                try c.decodeIfPresent([String].self, forKey: JMAPCodingKey("destroyed")) ?? []
            notDestroyed =
                try c.decodeIfPresent(
                    [String: NoteSetError].self, forKey: JMAPCodingKey("notDestroyed")) ?? [:]
        }

        /// The first refusal of any kind, for a caller that only needs to know
        /// whether the write landed.
        public var firstError: NoteSetError? {
            notCreated.values.first ?? notUpdated.values.first ?? notDestroyed.values.first
        }
    }

    public var arguments: Arguments

    public init(
        create: [String: NoteDraft] = [:], update: [String: NotePatch] = [:],
        destroy: [String] = [], ifInState: StateToken? = nil
    ) {
        arguments = Arguments(
            create: create, update: update, destroy: destroy, ifInState: ifInState)
    }
}
