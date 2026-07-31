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
    /// APNs, which is a different thing to `push`.
    ///
    /// `push` is Web Push and carries a VAPID key; Web Push cannot reach a
    /// native iOS app, so registering an APNs device token needs its own
    /// capability and its own method. Unlike `push`, this one *is* declarable
    /// in `using` — it has a method behind it — but only once the server has
    /// advertised it, which is why ``PushRegistrar`` checks first.
    case apns = "urn:de:plmail:params:jmap:apns"

    /// The capabilities a request may declare. Advertised ≠ usable.
    public static let supportedInUsing: Set<Capability> = [.core, .mail, .submission, .apns]

    public var isSupportedInUsing: Bool {
        Self.supportedInUsing.contains(self)
    }
}
