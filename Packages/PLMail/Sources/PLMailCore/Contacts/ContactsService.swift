import Foundation
public import JMAPKit
import OSLog
import Observation

/// BearerMail: the user's address book, as the server keeps it.
///
/// The iOS counterpart of the Android app's `ContactsRepository`. The whole
/// book is read in pages of 500 sorted by name — an address book is small
/// enough that searching it on the phone is faster than asking the server
/// on every keystroke — and every change is written straight through and
/// then re-read, so what is shown is what the server stored.
@MainActor
@Observable
public final class ContactsService {
    public private(set) var contacts: [Contact] = []
    /// Starts false, so "not known yet" draws exactly like "no".
    public private(set) var isAvailable = false
    public private(set) var isLoading = false
    public private(set) var failure: Failure?

    public enum Failure: Hashable, Sendable {
        case unreachable
        /// The server refused the change; `properties` names what it disliked
        /// when it said.
        case refused(properties: [String])
    }

    private let client: JMAPClient
    private var photos: [ContactID: Data] = [:]
    private let logger = Logger(subsystem: "de.plmail", category: "contacts")

    public init(client: JMAPClient) {
        self.client = client
    }

    // MARK: - Reading

    public func load() async {
        do {
            let session = try await client.session()
            isAvailable =
                session.capabilities.contacts != nil && session.contactsAccountID != nil
        } catch {
            logger.warning("Session unavailable, contacts stay as they were")
            return
        }

        await refresh()
    }

    public func refresh() async {
        guard isAvailable else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let session = try await client.session()
            guard let account = session.contactsAccountID else { return }

            var all: [Contact] = []
            var position = 0

            // Pages until a short one; a guard of 40 pages (20,000 contacts)
            // stops a misbehaving server from looping forever.
            for _ in 0..<40 {
                var builder = RequestBuilder(session: session)
                let query = builder.add(
                    ContactQuery(accountID: account, position: position))
                let get = builder.add(
                    ContactGet(
                        accountID: account,
                        ids: .reference(query.reference(path: "/ids"))))
                let results = try await client.send(builder)
                let ids = try results.result(of: query).ids
                let list = try results.result(of: get).list

                let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                all.append(contentsOf: ids.compactMap { byID[$0] })

                if ids.count < ContactQuery.maxLimit { break }
                position += ids.count
            }

            contacts = all
            failure = nil
        } catch {
            failure = .unreachable
            logger.warning("Contact/query failed, keeping the contacts already shown")
        }
    }

    public func contact(id: ContactID) -> Contact? {
        contacts.first { $0.id == id }
    }

    /// Mail exchanged with a contact, newest first. Empty when the server
    /// cannot say.
    public func recentMail(for id: ContactID) async -> [ContactReferenceEmail] {
        do {
            let session = try await client.session()
            guard let account = session.contactsAccountID else { return [] }
            var builder = RequestBuilder(session: session)
            let call = builder.add(ContactReferenceEmails(accountID: account, contactID: id))
            return try await client.send(builder).result(of: call).list
        } catch {
            return []
        }
    }

    // MARK: - Writing

    /// Creates a contact; returns its id, or nil when it did not land.
    @discardableResult
    public func create(_ draft: ContactDraft) async -> ContactID? {
        var draft = draft
        draft.isUpdate = false

        guard let result = await set({ ContactSet(accountID: $0, create: ["c1": draft]) })
        else { return nil }

        guard let id = result.created["c1"]?.id else {
            failure = .refused(properties: result.firstError?.properties ?? [])
            return nil
        }

        await refresh()
        return id
    }

    @discardableResult
    public func update(_ id: ContactID, _ draft: ContactDraft) async -> Bool {
        var draft = draft
        draft.isUpdate = true

        guard let result = await set({ ContactSet(accountID: $0, update: [id: draft]) }) else {
            return false
        }

        if let error = result.notUpdated[id] {
            failure = .refused(properties: error.properties ?? [])
            return false
        }

        await refresh()
        return true
    }

    @discardableResult
    public func delete(_ id: ContactID) async -> Bool {
        guard let result = await set({ ContactSet(accountID: $0, destroy: [id]) }) else {
            return false
        }

        if result.notDestroyed[id] != nil {
            failure = .refused(properties: [])
            return false
        }

        contacts.removeAll { $0.id == id }
        return true
    }

    private func set(_ make: (AccountID) -> ContactSet) async -> ContactSet.Result? {
        guard isAvailable else { return nil }

        do {
            let session = try await client.session()
            guard let account = session.contactsAccountID else { return nil }
            var builder = RequestBuilder(session: session)
            let call = builder.add(make(account))
            let result = try await client.send(builder).result(of: call)
            failure = nil
            return result
        } catch {
            failure = .unreachable
            logger.warning("Contact/set failed")
            return nil
        }
    }

    /// A contact's photo, from the server's same-origin photo URL, cached
    /// for the session. Nil when there is none.
    public func photo(for contact: Contact) async -> Data? {
        if let cached = photos[contact.id] { return cached }
        guard let raw = contact.photoURL, let url = URL(string: raw) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await client.authorized(request)
            guard (200..<300).contains(response.statusCode), data.isEmpty == false else {
                return nil
            }
            photos[contact.id] = data
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Duplicates

    /// The server's suggestions of people entered twice, most certain first.
    public func duplicates() async -> [ContactDuplicatePair] {
        do {
            let session = try await client.session()
            guard let account = session.contactsAccountID else { return [] }
            var builder = RequestBuilder(session: session)
            let call = builder.add(ContactDuplicates(accountID: account))
            return try await client.send(builder).result(of: call).pairs
                .filter { $0.ids.count >= 2 }
                .sorted { $0.confidence > $1.confidence }
        } catch {
            failure = .unreachable
            return []
        }
    }

    /// Merges `others` into `keep`. Returns the record that undoes it.
    public func merge(keep: ContactID, others: [ContactID]) async -> String? {
        guard others.isEmpty == false, others.contains(keep) == false else { return nil }
        do {
            let session = try await client.session()
            guard let account = session.contactsAccountID else { return nil }
            var builder = RequestBuilder(session: session)
            let call = builder.add(ContactMerge(accountID: account, keep: keep, merge: others))
            let record = try await client.send(builder).result(of: call).mergeRecordID
            await refresh()
            return record ?? ""
        } catch {
            failure = .unreachable
            return nil
        }
    }

    @discardableResult
    public func undoMerge(_ record: String) async -> Bool {
        do {
            let session = try await client.session()
            guard let account = session.contactsAccountID else { return false }
            var builder = RequestBuilder(session: session)
            let call = builder.add(ContactMergeUndo(accountID: account, mergeRecordID: record))
            _ = try await client.send(builder).result(of: call)
            await refresh()
            return true
        } catch {
            failure = .unreachable
            return false
        }
    }

    /// Every tag in use, sorted.
    public var tags: [String] {
        Array(Set(contacts.flatMap(\.tags))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
}
