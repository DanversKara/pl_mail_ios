import Foundation
import Observation

/// Where an intent's request goes.
///
/// Intents are constructed by the system, not by the app, so they cannot be
/// handed a reference to anything. This is the one place that indirection
/// lives.
@MainActor
@Observable
public final class IntentRouter {
    public static let shared = IntentRouter()

    public enum Request: Equatable, Sendable {
        case compose(recipient: String?, subject: String?)
        case search(String)
    }

    /// The most recent request, cleared once acted on. Not a queue: two
    /// intents arriving before the UI can respond means the second one is
    /// what the person most recently asked for.
    public private(set) var pending: Request?

    private init() {}

    public func request(_ request: Request) {
        pending = request
    }

    public func take() -> Request? {
        defer { pending = nil }

        return pending
    }
}
