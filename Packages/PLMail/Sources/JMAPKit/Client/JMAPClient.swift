import Foundation

/// Talks to one plMail server.
///
/// An actor rather than a global-actor-isolated type, so the sync engine (its
/// own actor) and the UI can both drive it without either being serialised
/// behind the other.
public actor JMAPClient {
    private let discoveryURL: URL
    private let credential: Credential
    private let transport: any JMAPTransport

    private var cachedSession: Session?
    private var sessionTask: Task<Session, any Error>?
    private var gate: RequestGate?

    public init(discoveryURL: URL, credential: Credential, transport: any JMAPTransport) {
        self.discoveryURL = discoveryURL
        self.credential = credential
        self.transport = transport
    }

    /// The Session object, fetched once and reused.
    ///
    /// Single-flighted: ten callers racing at launch — the sidebar, the feed,
    /// each account's syncer — cause one request, not ten. The in-flight task
    /// is what they share, so a failure propagates to all of them and the next
    /// caller retries rather than inheriting a cached error.
    public func session() async throws -> Session {
        if let cachedSession { return cachedSession }

        if let sessionTask { return try await sessionTask.value }

        let task = Task<Session, any Error> { [discoveryURL] in
            try await fetchSession(from: discoveryURL)
        }
        sessionTask = task

        defer { sessionTask = nil }

        let session = try await task.value
        cachedSession = session
        gate = RequestGate(session: session)

        return session
    }

    /// Discards the cached Session.
    ///
    /// Call on app foreground and after recovering from a 401 — the URLs in it
    /// are the server's to change, and a client that caches them across a
    /// reverse-proxy reconfiguration silently talks to the wrong place.
    public func invalidateSession() {
        cachedSession = nil
        sessionTask = nil
    }

    /// Sends one batch of method calls.
    public func send(_ builder: RequestBuilder) async throws -> MethodResults {
        guard builder.isEmpty == false else {
            throw JMAPError.malformedResponse("Refusing to send a request with no method calls.")
        }

        let session = try await session()
        let body = try builder.encoded()

        guard body.count <= session.capabilities.core.maxSizeRequestObject else {
            throw JMAPError.requestFailed(
                type: "requestTooLarge",
                detail: "Request body is \(body.count) bytes; this server accepts "
                    + "\(session.capabilities.core.maxSizeRequestObject)."
            )
        }

        var request = URLRequest(url: session.apiURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")

        let prepared = request
        let (data, response) = try await withPermit {
            try await self.transport.send(prepared)
        }

        return try MethodResults.decode(body: data, statusCode: response.statusCode)
    }

    /// Runs `body` holding one concurrency permit.
    ///
    /// Before the first Session arrives there is no advertised limit to
    /// respect, and the only request in flight is the discovery one — so the
    /// permit is skipped rather than guessed at.
    public func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        guard let gate else { return try await body() }
        return try await gate.withPermit(body)
    }

    /// Holds a permit back for as long as a long-lived connection is open.
    /// See ``RequestGate/reserve()``.
    public func reservePermit() async -> RequestGate.Reservation? {
        await gate?.reserve()
    }

    // MARK: - Session discovery

    private func fetchSession(from url: URL) async throws -> Session {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.send(request)

        switch response.statusCode {
        case 200:
            break
        case 401:
            let problem = try? JSONDecoder().decode(ProblemDocument.self, from: data)
            throw JMAPError.notAuthenticated(detail: problem?.detail)
        default:
            throw JMAPError.unexpectedStatus(code: response.statusCode)
        }

        do {
            return try JSONDecoder().decode(Session.self, from: data)
        } catch {
            throw JMAPError.malformedResponse(
                "\(url.absoluteString) did not return a JMAP session: \(error)"
            )
        }
    }
}

extension JMAPClient {
    /// Checks that an address and credential actually work, and reports what
    /// the server says it is.
    ///
    /// Used by onboarding to confirm before saving anything: the user sees
    /// their own address and their connected accounts and can tell at a glance
    /// whether this is the right server — which matters when the address they
    /// typed was `nas.local` and they have two of them.
    public func verify() async throws -> Session {
        invalidateSession()
        return try await session()
    }
}
