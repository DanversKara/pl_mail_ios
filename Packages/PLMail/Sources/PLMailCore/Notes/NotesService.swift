import Foundation
public import JMAPKit
import OSLog
import Observation

/// BearerMail: the user's notes, as the server holds them.
///
/// The iOS counterpart of the Android app's `NotesRepository`: one list read
/// with `Note/get`, and every change written with `Note/set` and applied here
/// first so the wall repaints without waiting a round trip. What the server
/// answers then replaces the optimistic copy, because the server is the truth.
///
/// Notes are per user, not per mail account, so there is one of these per
/// server connection rather than one per account.
@MainActor
@Observable
public final class NotesService {
    /// Every note, including archived and binned ones. Views filter.
    public private(set) var notes: [Note] = []
    /// Whether the server publishes notes at all. Starts false, so "not known
    /// yet" draws exactly like "no" and the sidebar row cannot flicker in.
    public private(set) var isAvailable = false
    public private(set) var isLoading = false
    /// The colour names the server accepts, in palette order.
    public private(set) var colors: [String] = NotesService.defaultColors
    /// Set when the last read or write did not land. Cleared by the next one
    /// that does.
    public private(set) var failure: Failure?

    public enum Failure: Hashable, Sendable {
        /// The server could not be reached.
        case unreachable
        /// The server refused the change.
        case refused
    }

    public static let defaultColors = [
        "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "brown", "gray",
    ]

    private var state: StateToken?
    private var nextCreationID = 0
    private let client: JMAPClient
    private let logger = Logger(subsystem: "de.plmail", category: "notes")

    public init(client: JMAPClient) {
        self.client = client
    }

    // MARK: - Reading

    /// Reads the Session to learn whether notes exist, then the notes.
    public func load() async {
        do {
            let session = try await client.session()
            let capabilities = session.capabilities.notes
            isAvailable = capabilities != nil
            if let colors = capabilities?.colors, colors.isEmpty == false {
                self.colors = colors
            }
        } catch {
            logger.warning("Session unavailable, notes stay as they were")
            return
        }

        await refresh()
    }

    /// Re-reads every note. Cheap: the list is one call, and a user's notes
    /// are a few hundred small objects at most.
    public func refresh() async {
        guard isAvailable else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(NoteGet())
            let result = try await client.send(builder).result(of: call)

            notes = result.list
            state = result.state
            failure = nil
        } catch {
            failure = .unreachable
            logger.warning("Note/get failed, keeping the notes already shown")
        }
    }

    public func note(id: String) -> Note? {
        notes.first { $0.id == id }
    }

    // MARK: - Writing

    /// Creates a note and returns it as the server stored it, or nil when the
    /// server refused or could not be reached.
    @discardableResult
    public func create(_ draft: NoteDraft) async -> Note? {
        guard isAvailable else { return nil }

        nextCreationID += 1
        let creationID = "n\(nextCreationID)"

        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(NoteSet(create: [creationID: draft]))
            let result = try await client.send(builder).result(of: call)

            guard let created = result.created[creationID] else {
                failure = .refused
                logger.warning("Note/set refused a new note")
                return nil
            }

            // The created object may carry only the server-set properties, so
            // what was sent fills in anything it left out.
            let note = merged(created, with: draft)
            notes.append(note)
            if let newState = result.newState { state = newState }
            failure = nil

            return note
        } catch {
            failure = .unreachable
            logger.warning("Note/set (create) failed")
            return nil
        }
    }

    /// Applies a change to one note: here at once, then on the server.
    ///
    /// When the server refuses, or cannot be reached, the note goes back to
    /// what it was, so the wall never shows a change the server does not hold.
    @discardableResult
    public func update(_ id: String, _ patch: NotePatch) async -> Bool {
        guard isAvailable, patch.isEmpty == false,
            let index = notes.firstIndex(where: { $0.id == id })
        else { return false }

        let previous = notes[index]
        notes[index] = previous.applying(patch)

        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(NoteSet(update: [id: patch]))
            let result = try await client.send(builder).result(of: call)

            if result.notUpdated[id] != nil {
                restore(previous)
                failure = .refused
                return false
            }

            if let stored = result.updated[id] ?? nil,
                let current = notes.firstIndex(where: { $0.id == id })
            {
                notes[current] = merged(stored, over: notes[current])
            }

            if let newState = result.newState { state = newState }
            failure = nil

            return true
        } catch {
            restore(previous)
            failure = .unreachable
            logger.warning("Note/set (update) failed")
            return false
        }
    }

    /// Deletes a note for good. Only offered from the bin.
    @discardableResult
    public func destroy(_ id: String) async -> Bool {
        guard isAvailable, let index = notes.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let previous = notes.remove(at: index)

        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(NoteSet(destroy: [id]))
            let result = try await client.send(builder).result(of: call)

            if result.notDestroyed[id] != nil {
                notes.insert(previous, at: min(index, notes.count))
                failure = .refused
                return false
            }

            if let newState = result.newState { state = newState }
            failure = nil

            return true
        } catch {
            notes.insert(previous, at: min(index, notes.count))
            failure = .unreachable
            return false
        }
    }

    /// Empties the bin.
    public func emptyBin() async {
        for note in notes where note.trashed {
            await destroy(note.id)
        }
    }

    // MARK: - Helpers

    private func restore(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        }
    }

    private func merged(_ created: Note, with draft: NoteDraft) -> Note {
        var note = created
        if note.title.isEmpty { note.title = draft.title }
        if note.body.isEmpty { note.body = draft.body }
        if note.items.isEmpty { note.items = draft.items }
        if note.color == nil { note.color = draft.color }
        if note.links.isEmpty { note.links = draft.links }
        if note.labels.isEmpty { note.labels = draft.labels }
        note.pinned = note.pinned || draft.pinned
        note.archived = note.archived || draft.archived
        return note
    }

    /// The server's answer to an update may be the whole note or only what
    /// it changed itself; an `updatedAt` alone must not wipe the text.
    private func merged(_ stored: Note, over local: Note) -> Note {
        stored.title.isEmpty && stored.body.isEmpty && stored.items.isEmpty
            ? local.with(updatedAt: stored.updatedAt ?? local.updatedAt)
            : stored
    }
}

extension Note {
    /// This note with every property the patch names written over it.
    public func applying(_ patch: NotePatch) -> Note {
        var note = self
        if let title = patch.title { note.title = title }
        if let body = patch.body { note.body = body }
        if let items = patch.items { note.items = items }
        if let color = patch.color { note.color = color }
        if let pinned = patch.pinned { note.pinned = pinned }
        if let archived = patch.archived { note.archived = archived }
        if let trashed = patch.trashed { note.trashed = trashed }
        if let links = patch.links { note.links = links }
        if let labels = patch.labels { note.labels = labels }
        if let reminderAt = patch.reminderAt { note.reminderAt = reminderAt }
        return note
    }

    func with(updatedAt: String?) -> Note {
        var note = self
        note.updatedAt = updatedAt
        return note
    }

    /// Every label across these notes, sorted, without repeats.
    public static func labels(in notes: [Note]) -> [String] {
        Array(Set(notes.flatMap(\.labels))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Whether the note contains every word of the query, in its title, text,
    /// checklist or labels.
    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard words.isEmpty == false else { return true }

        let haystack = ([title, body] + items.map(\.text) + labels).joined(separator: "\n")
        return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }
}
