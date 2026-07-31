/// An RFC 8621 `Thread`.
///
/// Named `MailThread` rather than `Thread` to stay clear of `Foundation.Thread`
/// at every call site.
///
/// Threading is currently RFC Message-ID based rather than Gmail-native, so
/// expect occasional divergence from what the Gmail web UI groups together.
public struct MailThread: Hashable, Sendable, Codable {
    public var id: ThreadID

    /// In date order, oldest first.
    public var emailIDs: [EmailID]

    /// When this conversation is due back — a **plMail extension**, not
    /// RFC 8621, which gives Thread only an id and its emails.
    ///
    /// The server nils an elapsed snooze rather than reporting a time in the
    /// past, so a non-nil value here is always still pending and nothing has to
    /// re-check the clock to know that.
    ///
    /// Note that nothing in plMail *filters* on this, the web list included: a
    /// snoozed conversation stays where it is and is badged. Hiding it here
    /// would make the two clients disagree about what an inbox contains.
    public var snoozedUntil: UTCDate?

    public init(id: ThreadID, emailIDs: [EmailID] = [], snoozedUntil: UTCDate? = nil) {
        self.id = id
        self.emailIDs = emailIDs
        self.snoozedUntil = snoozedUntil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case emailIDs = "emailIds"
        case snoozedUntil
    }
}
