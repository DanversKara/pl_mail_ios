/// A JMAP capability URN, as it appears in a Session object's `capabilities`
/// and in the `using` array of every request.
///
/// The distinction that matters: the server *advertises* four capabilities but
/// only accepts three in `using`. `push` is a plMail vendor extension carrying
/// the VAPID key — RFC 8620 defines no other place to put it — and sending it
/// in `using` is a hard 400, not a warning. Hence ``supportedInUsing``.
public enum Capability: String, Codable, CaseIterable, Sendable {
    case core = "urn:ietf:params:jmap:core"
    case mail = "urn:ietf:params:jmap:mail"
    case submission = "urn:ietf:params:jmap:submission"
    case push = "urn:plmail:params:jmap:push"

    /// The capabilities a request may declare. Advertised ≠ usable.
    public static let supportedInUsing: Set<Capability> = [.core, .mail, .submission]

    public var isSupportedInUsing: Bool {
        Self.supportedInUsing.contains(self)
    }
}
