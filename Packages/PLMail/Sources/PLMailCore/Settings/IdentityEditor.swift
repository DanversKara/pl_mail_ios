import Foundation
import JMAPKit
import OSLog
import Observation

/// The addresses this login can send from, and the one thing about them the
/// server will let a client change.
///
/// Reads from the store so the screen has something the instant it opens —
/// identities are synced with every refresh — and re-fetches behind that so a
/// rename made in the web UI turns up.
///
/// **Signatures are not editable, and that is a server fact, not an omission
/// here.** plMail stores an Identity as an alias row: an address and a display
/// name. `Identity/set` rejects `textSignature`, `htmlSignature`, `replyTo` and
/// `bcc` outright rather than accepting and discarding them, so there is no
/// honest way to offer a signature field. The screen says so instead of
/// presenting a text box that would silently lose what was typed into it.
@MainActor
@Observable
public final class IdentityEditor {
    /// One account's sendable addresses.
    public struct Group: Identifiable, Hashable, Sendable {
        public var accountKey: String
        public var accountID: AccountID
        public var accountName: String
        public var identities: [IdentitySnapshot]

        public var id: String { accountKey }
    }

    public private(set) var groups: [Group] = []
    /// True only until the first load lands, so the screen shows a spinner
    /// rather than an empty state it would immediately replace.
    public private(set) var isLoading = true
    /// A refresh that could not reach the server. The stored identities are
    /// still shown — they are what the composer will use either way — so this
    /// is a note, not a replacement for the list.
    public private(set) var refreshFailure: String?
    /// A rename the server refused.
    public private(set) var saveFailure: String?

    private let client: JMAPClient
    private let store: SyncStore
    private let accounts: [AccountSnapshot]
    private let logger = Logger(subsystem: "de.plmail", category: "identities")

    public init(client: JMAPClient, store: SyncStore, accounts: [AccountSnapshot]) {
        self.client = client
        self.store = store
        self.accounts = accounts
    }

    /// Cached first, then the server.
    public func load() async {
        await readFromStore()
        isLoading = false
        await refresh()
    }

    public func refresh() async {
        guard accounts.isEmpty == false else { return }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let calls = accounts.map {
                (account: $0, call: builder.add(IdentityGet(accountID: $0.accountID)))
            }
            let results = try await client.send(builder)

            for pair in calls {
                // Per account: one mailbox refusing `Identity/get` — a
                // disconnected provider, a permissions change — must not blank
                // the addresses of the ones that answered.
                guard let list = try? results.result(of: pair.call).list else { continue }

                try? await store.replaceIdentities(list, accountKey: pair.account.accountKey)
            }

            refreshFailure = nil
            await readFromStore()
        } catch {
            refreshFailure = String(
                localized: "Couldn't reach the server. Showing the addresses last synced.",
                bundle: .module)
            logger.error("Identity refresh failed: \(error, privacy: .public)")
        }
    }

    /// Renames one identity, server first.
    ///
    /// The opposite order to every other action in the app, and deliberately:
    /// mail actions are undoable, so an optimistic move that the server
    /// refuses can be quietly put back. A name is not undoable and is read
    /// aloud by every recipient's client, so it is worth the round trip to
    /// avoid showing a name as saved that was rejected.
    ///
    /// - Returns: Whether it was saved.
    @discardableResult
    public func rename(
        _ identity: IdentitySnapshot, in group: Group, to name: String
    ) async -> Bool {
        saveFailure = nil

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed != (identity.name ?? "") else { return true }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(
                IdentitySet.rename(identity.id, to: trimmed, accountID: group.accountID))
            let results = try await client.send(builder)

            if let error = results.failure(of: call) { throw error }

            let result = try results.result(of: call)

            // A 200 is not success: `Identity/set` reports per-object refusals
            // in notUpdated, the same trap as `Email/set`.
            if let refused = result.notUpdated, refused.isEmpty == false {
                saveFailure = Self.describe(refused)
                logger.error("Rename refused: \(String(describing: refused), privacy: .public)")

                return false
            }
        } catch {
            saveFailure = String(
                localized: "Couldn't reach the server. The name wasn't saved.", bundle: .module)
            logger.error("Rename failed: \(error, privacy: .public)")

            return false
        }

        await refresh()

        return true
    }

    /// Turns a per-object refusal into something a person can act on.
    ///
    /// `notFound` is not the error it sounds like, and it is the one a plMail
    /// user is most likely to see. An account with no alias rows still gets an
    /// `Identity/get` entry — a synthetic one, standing in for the account
    /// address itself, whose id is the *account's* id. `Identity/set` looks
    /// that id up among the account's aliases, does not find it, and says so.
    /// Reported verbatim it reads as "your address does not exist", which is
    /// alarming and wrong; what it means is that there is no row to rename.
    private static func describe(_ refusals: [IdentityID: JSONValue]) -> String {
        let type =
            refusals.values
            .compactMap { $0.objectValue?["type"]?.stringValue }
            .first

        return switch type {
        case "notFound":
            String(
                localized:
                    "This address isn't set up as an alias on the server, so its name comes from the account and can't be changed here.",
                bundle: .module)
        case "forbidden", "accountReadOnly":
            String(localized: "This account is read-only.", bundle: .module)
        default:
            String(localized: "The server wouldn't save that name.", bundle: .module)
        }
    }

    public func dismissSaveFailure() {
        saveFailure = nil
    }

    private func readFromStore() async {
        var built: [Group] = []

        for account in accounts {
            guard let identities = try? await store.identities(accountKey: account.accountKey),
                identities.isEmpty == false
            else { continue }

            built.append(
                Group(
                    accountKey: account.accountKey,
                    accountID: account.accountID,
                    accountName: account.displayName,
                    identities: identities.sorted { $0.email < $1.email }
                ))
        }

        groups = built
    }
}
