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

    public init(id: ThreadID, emailIDs: [EmailID] = []) {
        self.id = id
        self.emailIDs = emailIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case emailIDs = "emailIds"
    }
}
