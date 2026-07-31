import Foundation
import OSLog

/// A JMAP `StateChange` pushed over EventSource.
///
/// Deliberately tiny: JMAP never pushes mail, only the news that a state token
/// moved. The recipient then calls `/changes` to find out what.
public struct StateChange: Hashable, Sendable, Decodable {
    /// New state tokens by account id, then by object type.
    public var changed: [String: [String: String]]

    private enum CodingKeys: String, CodingKey {
        case changed
    }
}

/// Listens for state changes while the app is in front.
///
/// **This must never be held in the background.** Each connection occupies a
/// FrankenPHP worker for its entire life, and on a home NAS the pool is small —
/// N connected clients means N workers gone, and once they are all taken the
/// server stops answering ordinary requests, including the web UI. The server
/// hard-closes every connection at 300 seconds and expects a reconnect;
/// background delivery is Web Push's job, not this.
public actor EventSourceClient {
    /// The server closes cleanly at 300s. Treated as success, not an error:
    /// backing off after an expected close would make the stream progressively
    /// less live for no reason.
    static let expectedLifetime: Duration = .seconds(300)

    private let client: JMAPClient
    private let credential: Credential
    private let logger = Logger(subsystem: "de.plmail", category: "sse")

    private var task: Task<Void, Never>?
    private var reservation: RequestGate.Reservation?

    public init(client: JMAPClient, credential: Credential) {
        self.client = client
        self.credential = credential
    }

    public var isRunning: Bool { task != nil }

    /// Opens the stream, reconnecting until stopped.
    ///
    /// - Parameter onChange: Called for every state change, including the one
    ///   the server sends immediately on connect — which is why no separate
    ///   "catch up on connect" request is needed.
    public func start(onChange: @escaping @Sendable (StateChange) async -> Void) {
        guard task == nil else { return }

        // Held for the connection's life. SSE takes no JMAP slot in the
        // protocol's model, but it does take the resource that actually runs
        // out, so the request gate is narrowed to match.
        task = Task { [weak self] in
            await self?.reserveSlot()

            var attempt = 0

            while Task.isCancelled == false {
                let opened = Date.now

                do {
                    try await self?.listen(onChange: onChange)

                    // A clean close at roughly the expected lifetime is the
                    // server doing what it said it would.
                    let lived = Date.now.timeIntervalSince(opened)
                    attempt = lived >= 240 ? 0 : attempt + 1
                } catch is CancellationError {
                    break
                } catch {
                    attempt += 1
                    await self?.log(error)
                }

                guard Task.isCancelled == false else { break }

                if attempt > 0 {
                    // Only a *short* connection means something is wrong.
                    let backoff = min(pow(2, Double(attempt)), 300)
                    try? await Task.sleep(for: .seconds(backoff * Double.random(in: 0.5...1)))
                }
            }

            await self?.releaseSlot()
        }
    }

    /// Closes the stream.
    ///
    /// Called the moment the app stops being frontmost. The worker this holds
    /// is not the app's to keep.
    public func stop() {
        task?.cancel()
        task = nil

        let held = reservation
        reservation = nil

        Task { await held?.end() }
    }

    // MARK: - Connection

    private func listen(onChange: @escaping @Sendable (StateChange) async -> Void) async throws {
        let session = try await client.session()

        guard
            let url = session.eventSourceURL.expanded([
                "types": "Email,Thread,Mailbox",
                "closeafter": "no",
                "ping": "30",
            ])
        else { return }

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
        // Longer than the server's own 300s close, so the timeout never fires
        // before the close this expects.
        request.timeoutInterval = 360

        let (stream, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw JMAPError.unexpectedStatus(
                code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        var event = ""
        var data = ""

        for try await line in stream.lines {
            try Task.checkCancellation()

            if line.isEmpty {
                // A blank line ends an event.
                if event == "state", let change = Self.decode(data) {
                    await onChange(change)
                }

                event = ""
                data = ""
                continue
            }

            if let value = line.dropPrefix("event:") {
                event = value.trimmingCharacters(in: .whitespaces)
            } else if let value = line.dropPrefix("data:") {
                data += value.trimmingCharacters(in: .whitespaces)
            }
            // `ping` events and comments need no handling: their only job is
            // to keep the connection from being reaped by an intermediary.
        }
    }

    private static func decode(_ data: String) -> StateChange? {
        guard data.isEmpty == false else { return nil }

        return try? JSONDecoder().decode(StateChange.self, from: Data(data.utf8))
    }

    private func reserveSlot() async {
        reservation = await client.reservePermit()
    }

    private func releaseSlot() async {
        await reservation?.end()
        reservation = nil
    }

    private func log(_ error: any Error) {
        logger.error("Stream ended: \(error, privacy: .public)")
    }
}

extension String {
    fileprivate func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
