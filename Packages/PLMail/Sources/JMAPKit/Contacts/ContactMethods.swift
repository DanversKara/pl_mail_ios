import Foundation

// BearerMail: the address book — `Contact/query`, `Contact/get`, `Contact/set`
// and `Contact/referenceEmails`, the same calls and shapes the Android app uses
// (core/jmap ContactMethods.kt).
//
// **Declared under `mail`, like `ContactAutocomplete`.** The server checks only
// that every URN in `using` is one it supports; it does not tie a method to
// its own capability. Declaring `mail` works on every server, while the
// contacts URN would refuse the whole request on one that predates it. Whether
// to offer contacts at all is decided from the Session instead.

public typealias ContactID = String

public struct ContactEmail: Hashable, Sendable, Codable {
    public var email: String
    /// `home`, `work` or `other`.
    public var label: String
    public var isPrimary: Bool

    public init(email: String = "", label: String = "other", isPrimary: Bool = false) {
        self.email = email
        self.label = label
        self.isPrimary = isPrimary
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "other"
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
    }

    private enum CodingKeys: String, CodingKey { case email, label, isPrimary }
}

public struct ContactPhone: Hashable, Sendable, Codable {
    public var phone: String
    /// `home`, `work` or `other` — the only labels the server accepts.
    public var label: String
    public var isPrimary: Bool

    public init(phone: String = "", label: String = "other", isPrimary: Bool = false) {
        self.phone = phone
        self.label = label
        self.isPrimary = isPrimary
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "other"
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
    }

    private enum CodingKeys: String, CodingKey { case phone, label, isPrimary }
}

public struct ContactAddress: Hashable, Sendable, Codable {
    public var label: String
    public var street: String?
    public var city: String?
    public var region: String?
    public var postcode: String?
    public var country: String?

    public init(
        label: String = "home", street: String? = nil, city: String? = nil,
        region: String? = nil, postcode: String? = nil, country: String? = nil
    ) {
        self.label = label
        self.street = street
        self.city = city
        self.region = region
        self.postcode = postcode
        self.country = country
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "other"
        street = try c.decodeIfPresent(String.self, forKey: .street)
        city = try c.decodeIfPresent(String.self, forKey: .city)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        postcode = try c.decodeIfPresent(String.self, forKey: .postcode)
        country = try c.decodeIfPresent(String.self, forKey: .country)
    }

    /// Only the parts that have something in them, so an address with a city
    /// alone is not sent as four empty strings.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        for (key, value) in [
            (CodingKeys.street, street), (.city, city), (.region, region),
            (.postcode, postcode), (.country, country),
        ] {
            if let value = value?.trimmingCharacters(in: .whitespaces), value.isEmpty == false {
                try c.encode(value, forKey: key)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case label, street, city, region, postcode, country
    }

    /// The address on one line, for a list or a maps search.
    public var oneLine: String {
        [street, city, region, postcode, country]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
            .joined(separator: ", ")
    }

    public var isEmpty: Bool { oneLine.isEmpty }
}

/// One address-book entry.
public struct Contact: Hashable, Sendable, Decodable, Identifiable {
    public var id: ContactID
    public var displayName: String
    public var givenName: String?
    public var familyName: String?
    public var nickname: String?
    public var company: String?
    public var jobTitle: String?
    public var notes: String?
    public var tags: [String]
    public var photoURL: String?
    public var emails: [ContactEmail]
    public var phones: [ContactPhone]
    public var addresses: [ContactAddress]
    public var updatedAt: String?

    public init(id: ContactID, displayName: String) {
        self.id = id
        self.displayName = displayName
        tags = []
        emails = []
        phones = []
        addresses = []
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        givenName = try c.decodeIfPresent(String.self, forKey: .givenName)
        familyName = try c.decodeIfPresent(String.self, forKey: .familyName)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        company = try c.decodeIfPresent(String.self, forKey: .company)
        jobTitle = try c.decodeIfPresent(String.self, forKey: .jobTitle)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        photoURL = try c.decodeIfPresent(String.self, forKey: .photoURL)
        emails = try c.decodeIfPresent([ContactEmail].self, forKey: .emails) ?? []
        phones = try c.decodeIfPresent([ContactPhone].self, forKey: .phones) ?? []
        addresses = try c.decodeIfPresent([ContactAddress].self, forKey: .addresses) ?? []
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, givenName, familyName, nickname, company, jobTitle, notes
        case tags, emails, phones, addresses, updatedAt
        case photoURL = "photoUrl"
    }

    public var primaryEmail: ContactEmail? {
        emails.first(where: \.isPrimary) ?? emails.first
    }

    /// Two letters for the avatar: first and last word, or the first two
    /// letters of a one-word name.
    public var initials: String {
        let parts = displayName.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return "?" }
        if parts.count == 1 { return String(first.prefix(2)).uppercased() }
        return "\(first.prefix(1))\(parts.last?.prefix(1) ?? "")".uppercased()
    }

    /// Whether every word of the query is somewhere in the contact.
    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard words.isEmpty == false else { return true }
        let haystack = (
            [displayName, nickname ?? "", company ?? "", jobTitle ?? "", notes ?? ""]
                + emails.map(\.email) + phones.map(\.phone) + tags
        ).joined(separator: "\n")
        return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }
}

/// What the editor sends: a new contact whole, or an update with every field.
/// Blank optional text is left out rather than sent as an empty string.
public struct ContactDraft: Encodable, Sendable, Hashable {
    public var displayName: String
    public var givenName: String
    public var familyName: String
    public var nickname: String
    public var company: String
    public var jobTitle: String
    public var notes: String
    public var tags: [String]
    public var emails: [ContactEmail]
    public var phones: [ContactPhone]
    public var addresses: [ContactAddress]
    /// True for an update: blank fields are then sent as null so clearing one
    /// actually clears it on the server.
    public var isUpdate: Bool

    public init(
        displayName: String = "", givenName: String = "", familyName: String = "",
        nickname: String = "", company: String = "", jobTitle: String = "", notes: String = "",
        tags: [String] = [], emails: [ContactEmail] = [], phones: [ContactPhone] = [],
        addresses: [ContactAddress] = [], isUpdate: Bool = false
    ) {
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.company = company
        self.jobTitle = jobTitle
        self.notes = notes
        self.tags = tags
        self.emails = emails
        self.phones = phones
        self.addresses = addresses
        self.isUpdate = isUpdate
    }

    public init(_ contact: Contact) {
        self.init(
            displayName: contact.displayName, givenName: contact.givenName ?? "",
            familyName: contact.familyName ?? "", nickname: contact.nickname ?? "",
            company: contact.company ?? "", jobTitle: contact.jobTitle ?? "",
            notes: contact.notes ?? "", tags: contact.tags, emails: contact.emails,
            phones: contact.phones, addresses: contact.addresses, isUpdate: true)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: JMAPCodingKey.self)
        try c.encode(
            displayName.trimmingCharacters(in: .whitespaces), forKey: JMAPCodingKey("displayName"))

        for (key, value) in [
            ("givenName", givenName), ("familyName", familyName), ("nickname", nickname),
            ("company", company), ("jobTitle", jobTitle), ("notes", notes),
        ] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                try c.encode(trimmed, forKey: JMAPCodingKey(key))
            } else if isUpdate {
                try c.encodeNil(forKey: JMAPCodingKey(key))
            }
        }

        let cleanEmails = emails.filter {
            $0.email.trimmingCharacters(in: .whitespaces).isEmpty == false
        }
        let cleanPhones = phones.filter {
            $0.phone.trimmingCharacters(in: .whitespaces).isEmpty == false
        }
        let cleanAddresses = addresses.filter { $0.isEmpty == false }

        if isUpdate || tags.isEmpty == false { try c.encode(tags, forKey: JMAPCodingKey("tags")) }
        if isUpdate || cleanEmails.isEmpty == false {
            try c.encode(cleanEmails, forKey: JMAPCodingKey("emails"))
        }
        if isUpdate || cleanPhones.isEmpty == false {
            try c.encode(cleanPhones, forKey: JMAPCodingKey("phones"))
        }
        if isUpdate || cleanAddresses.isEmpty == false {
            try c.encode(cleanAddresses, forKey: JMAPCodingKey("addresses"))
        }
    }
}

// MARK: - Contact/query

public struct ContactQuery: JMAPMethod {
    public static let name = "Contact/query"
    public static let capability = Capability.mail
    /// The server's ceiling for one page.
    public static let maxLimit = 500

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var text: String?
        public var tag: String?
        /// `name` or `recent`.
        public var sort: String
        public var position: Int
        public var limit: Int

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: JMAPCodingKey.self)
            try c.encode(accountID, forKey: JMAPCodingKey("accountId"))
            var filter: [String: String] = [:]
            if let text, text.isEmpty == false { filter["text"] = text }
            if let tag, tag.isEmpty == false { filter["tag"] = tag }
            if filter.isEmpty == false { try c.encode(filter, forKey: JMAPCodingKey("filter")) }
            try c.encode(sort, forKey: JMAPCodingKey("sort"))
            try c.encode(position, forKey: JMAPCodingKey("position"))
            try c.encode(limit, forKey: JMAPCodingKey("limit"))
        }
    }

    public struct Result: Decodable, Sendable {
        public var ids: [ContactID]
        public var total: Int?
        public var position: Int?

        private enum CodingKeys: String, CodingKey { case ids, total, position }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ids = try c.decodeIfPresent([ContactID].self, forKey: .ids) ?? []
            total = try c.decodeIfPresent(Int.self, forKey: .total)
            position = try c.decodeIfPresent(Int.self, forKey: .position)
        }
    }

    public var arguments: Arguments

    public init(
        accountID: AccountID, text: String? = nil, tag: String? = nil, sort: String = "name",
        position: Int = 0, limit: Int = ContactQuery.maxLimit
    ) {
        arguments = Arguments(
            accountID: accountID, text: text, tag: tag, sort: sort, position: max(0, position),
            limit: min(max(1, limit), Self.maxLimit))
    }
}

// MARK: - Contact/get

public struct ContactGet: JMAPMethod {
    public static let name = "Contact/get"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var ids: Argument<[ContactID]>

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: JMAPCodingKey.self)
            try c.encode(accountID, forKey: JMAPCodingKey("accountId"))
            try ids.encode(into: &c, as: "ids")
        }
    }

    public struct Result: Decodable, Sendable {
        public var list: [Contact]
        public var notFound: [ContactID]

        private enum CodingKeys: String, CodingKey { case list, notFound }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            list = try c.decodeIfPresent([Contact].self, forKey: .list) ?? []
            notFound = try c.decodeIfPresent([ContactID].self, forKey: .notFound) ?? []
        }
    }

    public var arguments: Arguments

    public init(accountID: AccountID, ids: Argument<[ContactID]>) {
        arguments = Arguments(accountID: accountID, ids: ids)
    }
}

// MARK: - Contact/set

public struct ContactSetError: Hashable, Sendable, Decodable {
    public var type: MethodErrorType
    public var description: String?
    public var properties: [String]?
}

public struct ContactSet: JMAPMethod {
    public static let name = "Contact/set"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var create: [String: ContactDraft]
        public var update: [ContactID: ContactDraft]
        public var destroy: [ContactID]

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: JMAPCodingKey.self)
            try c.encode(accountID, forKey: JMAPCodingKey("accountId"))
            if create.isEmpty == false { try c.encode(create, forKey: JMAPCodingKey("create")) }
            if update.isEmpty == false { try c.encode(update, forKey: JMAPCodingKey("update")) }
            if destroy.isEmpty == false {
                try c.encode(destroy, forKey: JMAPCodingKey("destroy"))
            }
        }
    }

    public struct Created: Hashable, Sendable, Decodable {
        public var id: ContactID
    }

    public struct Result: Decodable, Sendable {
        public var created: [String: Created]
        public var notCreated: [String: ContactSetError]
        public var notUpdated: [String: ContactSetError]
        public var destroyed: [ContactID]
        public var notDestroyed: [String: ContactSetError]

        private enum CodingKeys: String, CodingKey {
            case created, notCreated, notUpdated, destroyed, notDestroyed
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            created = try c.decodeIfPresent([String: Created].self, forKey: .created) ?? [:]
            notCreated =
                try c.decodeIfPresent([String: ContactSetError].self, forKey: .notCreated) ?? [:]
            notUpdated =
                try c.decodeIfPresent([String: ContactSetError].self, forKey: .notUpdated) ?? [:]
            destroyed = try c.decodeIfPresent([ContactID].self, forKey: .destroyed) ?? []
            notDestroyed =
                try c.decodeIfPresent([String: ContactSetError].self, forKey: .notDestroyed)
                ?? [:]
        }

        public var firstError: ContactSetError? {
            notCreated.values.first ?? notUpdated.values.first ?? notDestroyed.values.first
        }
    }

    public var arguments: Arguments

    public init(
        accountID: AccountID, create: [String: ContactDraft] = [:],
        update: [ContactID: ContactDraft] = [:], destroy: [ContactID] = []
    ) {
        arguments = Arguments(accountID: accountID, create: create, update: update, destroy: destroy)
    }
}

// MARK: - Contact/referenceEmails

/// One mail exchanged with a contact, newest first.
public struct ContactReferenceEmail: Hashable, Sendable, Decodable, Identifiable {
    public var id: String
    public var subject: String?
    public var fromName: String?
    public var fromEmail: String?
    /// ISO 8601.
    public var date: String?
    public var mailbox: String?

    private enum CodingKeys: String, CodingKey { case id, subject, from, date, mailbox }
    private struct From: Decodable {
        var name: String?
        var email: String?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        let from = try c.decodeIfPresent(From.self, forKey: .from)
        fromName = from?.name
        fromEmail = from?.email
        date = try c.decodeIfPresent(String.self, forKey: .date)
        mailbox = try c.decodeIfPresent(String.self, forKey: .mailbox)
    }
}

public struct ContactReferenceEmails: JMAPMethod {
    public static let name = "Contact/referenceEmails"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var contactID: ContactID
        public var limit: Int

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case contactID = "contactId"
            case limit
        }
    }

    public struct Result: Decodable, Sendable {
        public var list: [ContactReferenceEmail]

        private enum CodingKeys: String, CodingKey { case list }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            list = try c.decodeIfPresent([ContactReferenceEmail].self, forKey: .list) ?? []
        }
    }

    public var arguments: Arguments

    public init(accountID: AccountID, contactID: ContactID, limit: Int = 50) {
        arguments = Arguments(accountID: accountID, contactID: contactID, limit: limit)
    }
}

// MARK: - Contact/duplicates, /merge, /mergeUndo

/// Two (or more) contacts the server thinks are the same person.
public struct ContactDuplicatePair: Hashable, Sendable, Decodable {
    public var ids: [ContactID]
    /// 0–100.
    public var confidence: Int
    /// Short machine words: `email`, `phone`, `name`.
    public var reasons: [String]

    private enum CodingKeys: String, CodingKey { case ids, confidence, reasons }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ids = try c.decodeIfPresent([ContactID].self, forKey: .ids) ?? []
        confidence = try c.decodeIfPresent(Int.self, forKey: .confidence) ?? 0
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
    }
}

public struct ContactDuplicates: JMAPMethod {
    public static let name = "Contact/duplicates"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        private enum CodingKeys: String, CodingKey { case accountID = "accountId" }
    }

    public struct Result: Decodable, Sendable {
        public var pairs: [ContactDuplicatePair]
        private enum CodingKeys: String, CodingKey { case pairs }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pairs = try c.decodeIfPresent([ContactDuplicatePair].self, forKey: .pairs) ?? []
        }
    }

    public var arguments: Arguments

    public init(accountID: AccountID) {
        arguments = Arguments(accountID: accountID)
    }
}

public struct ContactMerge: JMAPMethod {
    public static let name = "Contact/merge"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var keepID: ContactID
        public var mergeIDs: [ContactID]

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case keepID = "keepId"
            case mergeIDs = "mergeIds"
        }
    }

    public struct Result: Decodable, Sendable {
        public var mergeRecordID: String?
        private enum CodingKeys: String, CodingKey { case mergeRecordID = "mergeRecordId" }
    }

    public var arguments: Arguments

    public init(accountID: AccountID, keep: ContactID, merge: [ContactID]) {
        arguments = Arguments(accountID: accountID, keepID: keep, mergeIDs: merge)
    }
}

public struct ContactMergeUndo: JMAPMethod {
    public static let name = "Contact/mergeUndo"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var mergeRecordID: String

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case mergeRecordID = "mergeRecordId"
        }
    }

    public struct Result: Decodable, Sendable {}

    public var arguments: Arguments

    public init(accountID: AccountID, mergeRecordID: String) {
        arguments = Arguments(accountID: accountID, mergeRecordID: mergeRecordID)
    }
}
