import Foundation

/// A plMail server address as typed by a person.
///
/// There is no canonical plMail host — every instance is someone's own NAS,
/// VPS or Tailscale node — so the address is free text at onboarding, and what
/// people type is `nas.local`, `192.168.1.5:8080` or `mail.example.com/plmail`
/// far more often than a well-formed absolute URL. This normalises all of that
/// into a base URL and the session-discovery URL derived from it.
///
/// Two deliberate choices:
///
/// - **`https` is inferred when no scheme is typed.** `http` has to be asked
///   for explicitly, because silently downgrading someone's mail server to
///   cleartext is not a default anyone should get by accident.
/// - **A path is preserved.** Self-hosters reverse-proxy plMail under a
///   subpath often enough that discarding it would be a support burden, and
///   `/.well-known/jmap` is resolved relative to it.
public struct ServerAddress: Hashable, Sendable {
    /// The normalised origin (plus subpath, if any), with no trailing slash.
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Where session discovery starts. Everything else in JMAP — `apiUrl`,
    /// `uploadUrl`, `downloadUrl`, `eventSourceUrl` — is read out of the
    /// response and must never be reconstructed from this.
    public var sessionDiscoveryURL: URL {
        baseURL.appending(path: ".well-known/jmap")
    }

    /// True when the connection carries no transport security. The UI needs to
    /// say so plainly rather than quietly allowing it.
    public var isCleartext: Bool {
        baseURL.scheme?.lowercased() == "http"
    }

    public var host: String {
        baseURL.host() ?? baseURL.absoluteString
    }

    public enum ParseError: Error, Equatable, Sendable {
        case empty
        case unsupportedScheme(String)
        case missingHost
    }

    /// Parses what the user typed.
    ///
    /// - Throws: ``ParseError`` describing what is wrong, so onboarding can say
    ///   which part failed rather than "invalid URL".
    public static func parse(_ input: String) throws -> ServerAddress {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty == false else { throw ParseError.empty }

        // A bare "nas.local:8080" parses as scheme "nas.local" with an opaque
        // path, so the scheme is detected by "://" rather than by asking
        // URLComponents what it found.
        let hasScheme = trimmed.contains("://")
        let candidate = hasScheme ? trimmed : "https://\(trimmed)"

        guard var components = URLComponents(string: candidate) else {
            throw ParseError.missingHost
        }

        let scheme = (components.scheme ?? "https").lowercased()

        guard scheme == "https" || scheme == "http" else {
            throw ParseError.unsupportedScheme(scheme)
        }

        guard let host = components.host, host.isEmpty == false else {
            throw ParseError.missingHost
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.path = normalisedPath(components.path)
        // Neither survives a base URL, and carrying them would silently attach
        // whatever was pasted to every request made against this server.
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { throw ParseError.missingHost }

        return ServerAddress(baseURL: url)
    }

    /// Trailing slashes are dropped so the base URL has one spelling and
    /// `appending(path:)` cannot produce a doubled separator.
    private static func normalisedPath(_ path: String) -> String {
        var path = path

        while path.hasSuffix("/") {
            path.removeLast()
        }

        return path
    }
}
