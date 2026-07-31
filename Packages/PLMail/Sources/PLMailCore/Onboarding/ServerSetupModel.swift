import Foundation
import JMAPKit
import Observation

/// Drives connecting to a server for the first time.
///
/// Deliberately not in the view: the interesting behaviour here is the state
/// machine — what counts as a certificate the user should be asked about, what
/// gets shown before anything is written to the Keychain — and none of that
/// needs SwiftUI to be tested.
@MainActor
@Observable
public final class ServerSetupModel {
    public enum Phase: Equatable, Sendable {
        case editing
        case connecting
        /// Verified. Nothing is saved until the user confirms — they should be
        /// able to see whose mailbox they just reached before committing to it.
        case confirming(username: String, accounts: [String])
        /// The system rejected the certificate. The fingerprint is shown so it
        /// can be compared against the server before trusting it.
        case untrusted(host: String, fingerprint: KeyFingerprint)
        case failed(message: String)
    }

    public var addressText: String = ""
    public var secretText: String = ""
    public private(set) var phase: Phase = .editing

    private var verifiedConnection: ServerConnection?
    private let store: CredentialStore
    private let onConnected: @MainActor (ServerConnection) -> Void

    public init(
        store: CredentialStore = CredentialStore(),
        onConnected: @escaping @MainActor (ServerConnection) -> Void
    ) {
        self.store = store
        self.onConnected = onConnected
    }

    public var isBusy: Bool { phase == .connecting }

    /// Whether the fields are worth sending. Checked locally so an obviously
    /// mistyped secret says so immediately instead of after a round trip to a
    /// server that may be slow.
    public var canConnect: Bool {
        addressText.trimmingCharacters(in: .whitespaces).isEmpty == false
            && secretText.trimmingCharacters(in: .whitespaces).isEmpty == false
            && isBusy == false
    }

    /// Whether the secret is the right shape. Not an error while typing — only
    /// worth surfacing once they have stopped.
    public var secretLooksWrong: Bool {
        let trimmed = secretText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        return Credential.appPassword(trimmed).isWellFormed == false
    }

    // MARK: - Actions

    public func connect() async {
        await attempt(pinning: nil)
    }

    /// Retries, trusting the certificate the user was just shown.
    public func trustAndRetry() async {
        guard case .untrusted(_, let fingerprint) = phase else { return }
        await attempt(pinning: fingerprint)
    }

    /// Commits the verified connection to the Keychain.
    public func save() {
        guard let verifiedConnection else { return }

        do {
            try store.save(verifiedConnection)
            onConnected(verifiedConnection)
        } catch {
            phase = .failed(message: "Couldn't save to the keychain: \(error).")
        }
    }

    public func editAgain() {
        verifiedConnection = nil
        phase = .editing
    }

    // MARK: - Verification

    private func attempt(pinning fingerprint: KeyFingerprint?) async {
        phase = .connecting

        let trimmedSecret = secretText.trimmingCharacters(in: .whitespacesAndNewlines)

        let address: ServerAddress
        do {
            address = try ServerAddress.parse(addressText)
        } catch {
            phase = .failed(message: Self.describe(addressError: error))
            return
        }

        let connection = ServerConnection(
            address: address,
            credential: .appPassword(trimmedSecret),
            pinnedFingerprint: fingerprint
        )

        do {
            let session = try await connection.makeClient().verify()

            var verified = connection
            verified.username = session.username
            verifiedConnection = verified

            phase = .confirming(
                username: session.username,
                accounts: session.orderedAccounts.map(\.account.name)
            )
        } catch let error as JMAPError {
            phase = Self.phase(for: error, host: address.host)
        } catch {
            phase = .failed(message: "Something went wrong: \(error.localizedDescription)")
        }
    }

    /// Errors name the cause and, where possible, what to do about it — the
    /// register the server's own UI uses. Never "Error".
    private static func phase(for error: JMAPError, host: String) -> Phase {
        switch error {
        case .untrustedCertificate(let host, let fingerprint):
            if let fingerprint = KeyFingerprint(hex: fingerprint) {
                return .untrusted(host: host, fingerprint: fingerprint)
            }
            return .failed(message: "\(host) presented a certificate that couldn't be read.")

        case .notAuthenticated:
            return .failed(
                message: """
                    \(host) rejected that app password. It may have been revoked, or copied \
                    incompletely — it's shown only once, so it's easy to lose the last few \
                    characters.
                    """
            )

        case .unreachable(let host, _):
            return .failed(
                message: """
                    Can't reach \(host). Check the address, and that you're on the same network \
                    as the server if it's not published to the internet.
                    """
            )

        case .malformedResponse:
            return .failed(
                message: """
                    \(host) answered, but not with a JMAP session. Check the address points at \
                    plMail itself and not at a router or a landing page.
                    """
            )

        case .unexpectedStatus(let code):
            return .failed(message: "\(host) answered with HTTP \(code).")

        default:
            return .failed(message: "\(host) couldn't be reached: \(error).")
        }
    }

    private static func describe(addressError: any Error) -> String {
        switch addressError {
        case ServerAddress.ParseError.empty:
            "Enter your server's address."
        case ServerAddress.ParseError.unsupportedScheme(let scheme):
            "\(scheme):// isn't something this app can talk to. Use https, or http on a local network."
        case ServerAddress.ParseError.missingHost:
            "That address is missing a hostname."
        default:
            "That address couldn't be read."
        }
    }
}
