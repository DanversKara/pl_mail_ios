public import Foundation
public import JMAPKit
import Synchronization

/// A plMail server with a synthetic corpus, good enough to page against.
///
/// Not a stub that replays a canned response — it actually implements
/// `Email/query`'s `before` and `limit`, `Email/get`'s repository ordering and
/// `Thread/get`. That matters because the thing under test is a merge across
/// several paged sources, and every interesting failure it can have — a
/// duplicate at a page boundary, a row dropped where timestamps collide, a gap
/// when mail arrives mid-paging — only appears when paging behaves like paging.
///
/// It also reproduces two server behaviours a client will otherwise get wrong:
/// `Email/get` answers in id order rather than the order asked for, and one
/// account can fail while its siblings succeed.
public final class FakeMailServer: Sendable {
    public struct Message: Sendable, Hashable {
        public var id: String
        public var threadID: String
        public var subject: String
        public var from: String
        public var receivedAt: Date
        public var isSeen: Bool

        public init(
            id: String,
            threadID: String? = nil,
            subject: String = "Subject",
            from: String = "sender@example.test",
            receivedAt: Date,
            isSeen: Bool = false
        ) {
            self.id = id
            self.threadID = threadID ?? "t\(id)"
            self.subject = subject
            self.from = from
            self.receivedAt = receivedAt
            self.isSeen = isSeen
        }
    }

    private struct State {
        var accounts: [String: [Message]] = [:]
        var failing: Set<String> = []
        var queryCount = 0
    }

    private let state = Mutex(State())
    private let mailboxID = "1"

    public init(accounts: [String: [Message]] = [:]) {
        state.withLock { $0.accounts = accounts }
    }

    // MARK: - Corpus control

    public func setMessages(_ messages: [Message], accountID: String) {
        state.withLock { $0.accounts[accountID] = messages }
    }

    /// Inserts mail *while* a merge is in progress, which is how the
    /// mid-paging insertion case is exercised.
    public func insert(_ message: Message, accountID: String) {
        state.withLock { $0.accounts[accountID, default: []].append(message) }
    }

    /// Makes one account fail every request, leaving the others healthy.
    public func setFailing(_ isFailing: Bool, accountID: String) {
        state.withLock {
            if isFailing {
                $0.failing.insert(accountID)
            } else {
                $0.failing.remove(accountID)
            }
        }
    }

    public var queryCount: Int { state.withLock(\.queryCount) }

    public var accountIDs: [String] { state.withLock { $0.accounts.keys.sorted() } }

    // MARK: - Transport

    public func makeTransport() -> MockTransport {
        MockTransport { [self] request in
            let isDiscovery = request.url?.path.hasSuffix("/.well-known/jmap") == true
            let body =
                isDiscovery
                ? try sessionJSON()
                : try respond(to: request.httpBody ?? Data())

            return (body, MockTransport.response(for: request))
        }
    }

    public func makeClient(
        credential: Credential = .appPassword("plmail_" + String(repeating: "a", count: 64))
    ) -> JMAPClient {
        JMAPClient(
            discoveryURL: URL(string: "https://fake.test/.well-known/jmap")!,
            credential: credential,
            transport: makeTransport()
        )
    }

    // MARK: - Session

    private func sessionJSON() throws -> Data {
        let ids = accountIDs

        let accounts = ids.map { id in
            """
            "\(id)": {
              "name": "account-\(id)@example.test",
              "isPersonal": true,
              "isReadOnly": false,
              "accountCapabilities": { "urn:ietf:params:jmap:mail": {} }
            }
            """
        }

        return Data(
            """
            {
              "capabilities": {
                "urn:ietf:params:jmap:core": {
                  "maxSizeUpload": 50000000, "maxConcurrentUpload": 4,
                  "maxSizeRequestObject": 10000000, "maxConcurrentRequests": 4,
                  "maxCallsInRequest": 32, "maxObjectsInGet": 500,
                  "maxObjectsInSet": 500, "collationAlgorithms": []
                }
              },
              "accounts": { \(accounts.joined(separator: ",")) },
              "primaryAccounts": { "urn:ietf:params:jmap:mail": "\(ids.first ?? "1")" },
              "username": "fake@example.test",
              "apiUrl": "https://fake.test/jmap/api",
              "downloadUrl": "https://fake.test/jmap/download/{accountId}/{blobId}/{name}",
              "uploadUrl": "https://fake.test/jmap/upload/{accountId}",
              "eventSourceUrl": "https://fake.test/jmap/eventsource",
              "state": "1"
            }
            """.utf8
        )
    }

    // MARK: - API

    private func respond(to body: Data) throws -> Data {
        guard let request = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            let calls = request["methodCalls"] as? [[Any]]
        else {
            throw FakeError.badRequest
        }

        var responses: [[Any]] = []
        // Results of earlier calls in the same request, so back-references can
        // be resolved the way the real server resolves them.
        var byCallID: [String: [String: Any]] = [:]

        for call in calls {
            guard let name = call.first as? String,
                let arguments = call.count > 1 ? call[1] as? [String: Any] : nil,
                let callID = call.count > 2 ? call[2] as? String : nil
            else { continue }

            let accountID = arguments["accountId"] as? String ?? ""

            if state.withLock({ $0.failing.contains(accountID) }) {
                responses.append(["error", ["type": "serverUnavailable"], callID])
                continue
            }

            let result: [String: Any]

            switch name {
            case "Email/query": result = emailQuery(arguments, accountID: accountID)
            case "Email/get": result = emailGet(arguments, accountID: accountID, prior: byCallID)
            case "Thread/get": result = threadGet(arguments, accountID: accountID, prior: byCallID)
            case "Mailbox/get": result = mailboxGet(accountID: accountID)
            default:
                responses.append(["error", ["type": "unknownMethod"], callID])
                continue
            }

            byCallID[callID] = result
            responses.append([name, result, callID])
        }

        return try JSONSerialization.data(
            withJSONObject: ["methodResponses": responses, "sessionState": "1"])
    }

    private func emailQuery(_ arguments: [String: Any], accountID: String) -> [String: Any] {
        state.withLock { $0.queryCount += 1 }

        let before = boundDate(in: arguments["filter"])
        let limit = arguments["limit"] as? Int ?? 50

        var matching = messages(accountID)
            .sorted { $0.receivedAt > $1.receivedAt }

        if let before {
            // Strict `<`, exactly as the server compiles it. Getting this
            // wrong would hide the tie case the client's boundary tracking
            // exists to handle.
            matching = matching.filter { $0.receivedAt < before }
        }

        // collapseThreads: one message per thread, the newest.
        var seenThreads: Set<String> = []
        matching = matching.filter { seenThreads.insert($0.threadID).inserted }

        let page = Array(matching.prefix(limit))

        return [
            "accountId": accountID,
            "queryState": "q1",
            "canCalculateChanges": false,
            "position": 0,
            "ids": page.map(\.id),
            "total": matching.count,
        ]
    }

    private func emailGet(
        _ arguments: [String: Any], accountID: String, prior: [String: [String: Any]]
    ) -> [String: Any] {
        let ids = resolveIDs(arguments, key: "ids", prior: prior)
        let wanted = Set(ids)

        // Repository order, not requested order — the real server does this,
        // and a client that forgets to re-order shows a list sorted by
        // database id.
        let found = messages(accountID)
            .filter { wanted.contains($0.id) }
            .sorted { $0.id < $1.id }

        return [
            "accountId": accountID,
            "state": "e1",
            "list": found.map { message in
                [
                    "id": message.id,
                    "threadId": message.threadID,
                    "subject": message.subject,
                    "from": [["name": message.from, "email": message.from]],
                    "receivedAt": Self.format(message.receivedAt),
                    "preview": "preview of \(message.subject)",
                    "keywords": message.isSeen ? ["$seen": true] : [:],
                    "hasAttachment": false,
                    "mailboxIds": [mailboxID: true],
                ] as [String: Any]
            },
            "notFound": ids.filter { id in found.contains { $0.id == id } == false },
        ]
    }

    private func threadGet(
        _ arguments: [String: Any], accountID: String, prior: [String: [String: Any]]
    ) -> [String: Any] {
        let ids = Set(resolveIDs(arguments, key: "ids", prior: prior))
        let all = messages(accountID)

        let threads = ids.sorted().map { threadID in
            [
                "id": threadID,
                "emailIds": all.filter { $0.threadID == threadID }.map(\.id).sorted(),
            ] as [String: Any]
        }

        return ["accountId": accountID, "state": "t1", "list": threads, "notFound": []]
    }

    private func mailboxGet(accountID: String) -> [String: Any] {
        [
            "accountId": accountID,
            "state": "m1",
            "list": [
                [
                    "id": mailboxID,
                    "labelId": "100",
                    "name": "Inbox",
                    "parentId": NSNull(),
                    "role": "inbox",
                    "sortOrder": 0,
                    "totalEmails": messages(accountID).count,
                    "unreadEmails": messages(accountID).filter { $0.isSeen == false }.count,
                    "totalThreads": Set(messages(accountID).map(\.threadID)).count,
                    "unreadThreads": 0,
                    "myRights": ["mayRename": false, "mayDelete": false],
                    "isSubscribed": true,
                ] as [String: Any]
            ],
            "notFound": [],
        ]
    }

    // MARK: - Helpers

    private func messages(_ accountID: String) -> [Message] {
        state.withLock { $0.accounts[accountID] ?? [] }
    }

    /// Resolves either a literal `ids` or a `#ids` back-reference, including
    /// the `/list/*/threadId` wildcard the client uses to chain Thread/get
    /// onto Email/get.
    private func resolveIDs(
        _ arguments: [String: Any], key: String, prior: [String: [String: Any]]
    ) -> [String] {
        if let literal = arguments[key] as? [String] { return literal }

        guard let reference = arguments["#\(key)"] as? [String: Any],
            let resultOf = reference["resultOf"] as? String,
            let path = reference["path"] as? String,
            let source = prior[resultOf]
        else { return [] }

        if path == "/ids" { return source["ids"] as? [String] ?? [] }

        if path.hasPrefix("/list/*/") {
            let property = String(path.dropFirst("/list/*/".count))
            let list = source["list"] as? [[String: Any]] ?? []

            return list.compactMap { $0[property] as? String }
        }

        return []
    }

    private func boundDate(in filter: Any?) -> Date? {
        guard let filter = filter as? [String: Any] else { return nil }

        if let before = filter["before"] as? String { return Self.parse(before) }

        if let conditions = filter["conditions"] as? [[String: Any]] {
            for condition in conditions {
                if let found = boundDate(in: condition) { return found }
            }
        }

        return nil
    }

    private static let formatter = Date.ISO8601FormatStyle(timeZone: .gmt)

    public static func format(_ date: Date) -> String { date.formatted(formatter) }
    public static func parse(_ text: String) -> Date? { try? Date(text, strategy: formatter) }

    enum FakeError: Error { case badRequest }
}
