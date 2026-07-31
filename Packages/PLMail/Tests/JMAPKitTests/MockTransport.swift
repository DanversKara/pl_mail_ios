import Foundation
import Synchronization

@testable import JMAPKit

/// A transport that answers from a script instead of a network.
///
/// Records every request so tests can assert on what was actually sent — the
/// authorization header, the concurrency, the number of round trips — none of
/// which is observable from the decoded result.
final class MockTransport: JMAPTransport {
    struct Recorded: Sendable {
        var url: URL
        var method: String
        var authorization: String?
        var body: Data?
    }

    private struct State {
        var recorded: [Recorded] = []
        var inFlight = 0
        var peakInFlight = 0
    }

    private let state = Mutex(State())
    private let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    /// Always answers with the same body and status.
    convenience init(body: Data, statusCode: Int = 200, delay: Duration = .zero) {
        self.init { request in
            if delay > .zero { try await Task.sleep(for: delay) }

            return (
                body,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    }

    var recorded: [Recorded] { state.withLock(\.recorded) }
    var requestCount: Int { state.withLock(\.recorded.count) }

    /// The most requests that were ever in flight at once — how the gate is
    /// tested without depending on timing.
    var peakConcurrency: Int { state.withLock(\.peakInFlight) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        state.withLock {
            $0.recorded.append(
                Recorded(
                    url: request.url!,
                    method: request.httpMethod ?? "GET",
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    body: request.httpBody
                )
            )
            $0.inFlight += 1
            $0.peakInFlight = max($0.peakInFlight, $0.inFlight)
        }

        defer { state.withLock { $0.inFlight -= 1 } }

        return try await handler(request)
    }
}
