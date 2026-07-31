#if os(iOS)

public import PLMailCore

import Foundation

/// What a list row pushes.
///
/// A value rather than a model object: navigation state outlives the view
/// that created it, and `@Model` types are not `Sendable` and must not
/// leave the actor that owns their context.
public struct ThreadRef: Hashable, Sendable {
    public var threadID: String
    public var accountKey: String
    public var subject: String

    init(thread: StoredThread) {
        threadID = thread.threadID
        accountKey = thread.accountKey
        subject = thread.subject.flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)"
    }
}

#endif
