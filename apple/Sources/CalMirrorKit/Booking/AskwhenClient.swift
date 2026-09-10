import Foundation

/// A request the owner has to answer, as the queue delivers it.
///
/// The requester's name, address and note are here because the owner needs
/// them to decide. They are shown, never stored on this side beyond the
/// accepted event's body, and the service purges them on its own schedule.
public struct IncomingRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let slot: Slot
    public let name: String
    public let email: String
    public let note: String?
    /// While the service still holds the time for this request. Past it, the
    /// slot is on offer again and somebody else may have asked; the accept
    /// path re-checks the calendar either way.
    public let holdUntil: Date

    enum CodingKeys: String, CodingKey {
        case id, name, email, note
        case slotStart = "slot_start", slotEnd = "slot_end", holdUntil = "hold_until"
    }

    public init(id: String, slot: Slot, name: String, email: String, note: String?, holdUntil: Date) {
        self.id = id; self.slot = slot; self.name = name; self.email = email
        self.note = note; self.holdUntil = holdUntil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
        let s = try c.decode(String.self, forKey: .slotStart)
        let e = try c.decode(String.self, forKey: .slotEnd)
        let h = try c.decode(String.self, forKey: .holdUntil)
        guard let start = ISO8601.date(from: s), let end = ISO8601.date(from: e), let hold = ISO8601.date(from: h) else {
            throw DecodingError.dataCorruptedError(forKey: .slotStart, in: c,
                                                   debugDescription: "timestamps must be ISO-8601")
        }
        slot = Slot(start: start, end: end)
        holdUntil = hold
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(email, forKey: .email)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(ISO8601.string(from: slot.start), forKey: .slotStart)
        try c.encode(ISO8601.string(from: slot.end), forKey: .slotEnd)
        try c.encode(ISO8601.string(from: holdUntil), forKey: .holdUntil)
    }
}

/// What can go wrong talking to the service, reduced to what the caller can do
/// about it.
public enum AskwhenError: Error, Equatable, Sendable {
    /// The page, request or token is not known. The service says 404 for all
    /// three on purpose (architecture §4c), so this side cannot tell either —
    /// and should not try. A wrong token and a deleted page look the same.
    case notFound
    /// The service understood and refused: a dump that fails validation, a
    /// decision it does not recognise. The message is the service's own.
    case rejected(String)
    /// Try again later. 5xx, or Postal-shaped trouble behind it.
    case unavailable
    /// The network, DNS, TLS — nothing the service said.
    case transport(String)
    /// The response was not what the contract promises.
    case malformed
}

/// One HTTP exchange. A protocol so the client is testable from `cmk-check`
/// with no network: the fake records the request and answers as the service
/// would.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: Transport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw AskwhenError.malformed }
        return (data, http)
    }
}

/// The owner's five calls, and the one that creates a page.
///
/// Nothing here retries. A publish that fails is re-derived and re-attempted on
/// the next sync cycle; a poll that fails is polled again; a resolve that fails
/// is the caller's to retry, because the event may already have been written.
public struct AskwhenClient: Sendable {
    public let baseURL: URL
    private let transport: Transport

    public static let production = URL(string: "https://askwhen.me")!

    public init(baseURL: URL = AskwhenClient.production, transport: Transport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    // MARK: Create

    public struct Created: Equatable, Sendable {
        public let slug: String
        /// Shown exactly once. Store it before doing anything else.
        public let writeToken: String
    }

    /// `entitlementHash` is SHA-256 hex of the StoreKit originalTransactionId,
    /// computed on the device; the service never sees the id itself.
    public func createPage(entitlementHash: String, display: PolicyDump.Display) async throws -> Created {
        var req = request("POST", "/v1/pages", token: nil)
        struct Body: Encodable { let entitlement_hash: String; let display: PolicyDump.Display }
        req.httpBody = try JSONEncoder().encode(Body(entitlement_hash: entitlementHash, display: display))
        let (data, resp) = try await exchange(req)
        guard resp.statusCode == 201 else { throw failure(resp, data) }
        struct Reply: Decodable { let slug: String; let write_token: String }
        guard let r = try? JSONDecoder().decode(Reply.self, from: data), !r.slug.isEmpty, !r.write_token.isEmpty else {
            throw AskwhenError.malformed
        }
        return Created(slug: r.slug, writeToken: r.write_token)
    }

    // MARK: Publish

    /// PUTs the dump's bytes as given. Returns the service's strong ETag.
    public func publish(_ dump: Data, slug: String, token: String) async throws -> String {
        var req = request("PUT", "/v1/pages/\(slug)", token: token)
        req.httpBody = dump
        let (data, resp) = try await exchange(req)
        guard resp.statusCode == 204 else { throw failure(resp, data) }
        return resp.value(forHTTPHeaderField: "ETag") ?? ""
    }

    public func deletePage(slug: String, token: String) async throws {
        let (data, resp) = try await exchange(request("DELETE", "/v1/pages/\(slug)", token: token))
        guard resp.statusCode == 204 else { throw failure(resp, data) }
    }

    // MARK: Collect

    public enum QueueResult: Equatable, Sendable {
        /// 304: nothing has changed since `etag`.
        case unchanged
        case changed([IncomingRequest], etag: String?)
    }

    /// Polls the queue. Pass the ETag from the last `.changed` and an idle poll
    /// costs one round trip and no body.
    public func queue(slug: String, token: String, ifNoneMatch etag: String?) async throws -> QueueResult {
        var req = request("GET", "/v1/pages/\(slug)/queue", token: token)
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, resp) = try await exchange(req)
        switch resp.statusCode {
        case 304:
            return .unchanged
        case 200:
            struct Reply: Decodable { let requests: [IncomingRequest] }
            guard let r = try? JSONDecoder().decode(Reply.self, from: data) else { throw AskwhenError.malformed }
            return .changed(r.requests, etag: resp.value(forHTTPHeaderField: "ETag"))
        default:
            throw failure(resp, data)
        }
    }

    // MARK: Resolve

    public enum Decision: String, Sendable { case accept, decline }

    /// 204 means recorded and the requester's email is on its way. 404 means
    /// already answered, expired, or not this page's — the caller cannot tell
    /// which, and treating all three as "done" is correct.
    public func resolve(requestID: String, slug: String, decision: Decision, token: String) async throws {
        var req = request("POST", "/v1/requests/\(requestID)/resolve", token: token)
        struct Body: Encodable { let slug: String; let decision: String }
        req.httpBody = try JSONEncoder().encode(Body(slug: slug, decision: decision.rawValue))
        let (data, resp) = try await exchange(req)
        guard resp.statusCode == 204 else { throw failure(resp, data) }
    }

    // MARK: Plumbing

    private func request(_ method: String, _ path: String, token: String?) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("CalendarMirror", forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func exchange(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(req)
        } catch let e as AskwhenError {
            throw e
        } catch {
            throw AskwhenError.transport(error.localizedDescription)
        }
    }

    private func failure(_ resp: HTTPURLResponse, _ data: Data) -> AskwhenError {
        switch resp.statusCode {
        case 404: return .notFound
        case 400...499:
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .rejected(text.isEmpty ? "HTTP \(resp.statusCode)" : text)
        default: return .unavailable
        }
    }
}
