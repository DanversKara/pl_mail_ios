import Contacts
import Foundation
import JMAPKit
import OSLog

/// Where recipient suggestions come from.
///
/// Two sources, deliberately kept separate until the last moment. Mail already
/// synced knows who you actually correspond with; the address book knows people
/// you have never emailed from this device — a new colleague, someone whose
/// card arrived over AirDrop. Neither is a superset of the other, and the
/// ranking between them is the interesting part.
public protocol ContactSource: Sendable {
    /// Addresses whose name or email begins with, or contains, `fragment`.
    func addresses(matching fragment: String) async -> [EmailAddress]
}

/// The system address book.
///
/// Access is asked for **when someone first types a recipient**, not at launch.
/// A mail client demanding the address book on first run, before it has shown
/// you a single message, is the behaviour that teaches people to say no.
public actor SystemContacts: ContactSource {
    private let store = CNContactStore()
    private let logger = Logger(subsystem: "de.plmail", category: "contacts")

    /// Cached because `CNContactStore.enumerate` is not free and this is called
    /// on a keystroke. Contacts do not change often enough for a session-length
    /// cache to be wrong in a way anyone notices.
    private var cache: [EmailAddress]?
    private var hasAsked = false

    public init() {}

    public func addresses(matching fragment: String) async -> [EmailAddress] {
        let fragment = fragment.trimmingCharacters(in: .whitespaces).lowercased()

        // Two characters before touching the address book at all: one letter
        // matches most of it, and the result is a permission prompt for a list
        // nobody can use.
        guard fragment.count >= 2 else { return [] }

        guard let all = await everyone() else { return [] }

        return all.filter {
            $0.email.lowercased().contains(fragment)
                || ($0.name?.lowercased().contains(fragment) ?? false)
        }
    }

    private func everyone() async -> [EmailAddress]? {
        if let cache { return cache }

        guard await isAuthorised() else { return nil }

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey]
        let request = CNContactFetchRequest(keysToFetch: keys as [CNKeyDescriptor])
        var found: [EmailAddress] = []

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = CNContactFormatter.string(from: contact, style: .fullName)

                for entry in contact.emailAddresses {
                    let email = entry.value as String

                    guard email.isEmpty == false else { continue }

                    found.append(EmailAddress(name: name, email: email))
                }
            }
        } catch {
            // A refused or broken address book is not an error worth showing.
            // Suggestions simply come from mail, as they did before.
            logger.error("Could not read contacts: \(error, privacy: .public)")

            return nil
        }

        cache = found

        return found
    }

    private func isAuthorised() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return true

        case .notDetermined:
            // Only once per launch. Repeatedly asking a system that has already
            // said "not now" is how an app ends up permanently denied.
            guard hasAsked == false else { return false }

            hasAsked = true

            return (try? await store.requestAccess(for: .contacts)) ?? false

        default:
            return false
        }
    }
}

/// Merges the two sources into one ordered list.
///
/// Pure, and therefore the part that can actually be tested — the address book
/// itself cannot be, not without a device and a person tapping Allow.
public enum RecipientSuggestions {
    /// Correspondents first, then the address book.
    ///
    /// Somebody you have emailed is a better guess than somebody whose card you
    /// happen to hold, and on a phone only the first few suggestions are ever
    /// seen. Within each group the incoming order is kept: mail arrives most
    /// recent first, and contacts arrive in the address book's own sort.
    ///
    /// Matching is on a prefix first and a substring second, because typing
    /// "ada" should offer Ada before it offers everyone at `nomad.example`.
    public static func merge(
        correspondents: [EmailAddress],
        contacts: [EmailAddress],
        matching fragment: String,
        limit: Int = 5
    ) -> [EmailAddress] {
        let fragment = fragment.trimmingCharacters(in: .whitespaces).lowercased()

        guard fragment.count >= 2 else { return [] }

        var seen: Set<String> = []
        var prefix: [EmailAddress] = []
        var substring: [EmailAddress] = []

        for address in correspondents + contacts {
            let key = address.email.lowercased()

            // The same person is usually in both lists. Whichever source got
            // there first wins, which is what puts correspondents on top.
            guard key.isEmpty == false, seen.insert(key).inserted else { continue }

            let name = address.name?.lowercased() ?? ""

            // Per word, not just the whole string: a surname is a normal thing
            // to type, and "love" should rank Ada Lovelace as a prefix match
            // rather than burying her among everyone at nomad.example.
            let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" })

            if key.hasPrefix(fragment) || words.contains(where: { $0.hasPrefix(fragment) }) {
                prefix.append(address)
            } else if key.contains(fragment) || name.contains(fragment) {
                substring.append(address)
            }
        }

        return Array((prefix + substring).prefix(limit))
    }
}
