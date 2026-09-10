import Foundation

/// Everything the device keeps about its request page. Lives inside `Config`
/// so it is saved, loaded and hand-editable the way mirrors are, and so the
/// two request checkboxes in Manage Mirrors (architecture §3) have somewhere to
/// write.
///
/// What is **not** here: the write token. It is the only credential the service
/// ever issues, and a config file in Application Support is the wrong place for
/// the one thing that must not be copied around with the rest. It lives in the
/// Keychain behind `TokenStore`, keyed by slug.
public struct RequestPageConfig: Codable, Equatable, Sendable {

    /// Assigned by the service at creation. Empty until then, and nothing
    /// publishes or polls while it is.
    public var slug: String
    public var enabled: Bool

    public var policy: RequestPolicy

    /// The single identifying field in the dump. Free text, chosen in the
    /// knowledge that it is public.
    public var displayName: String
    public var blurb: String?
    /// Set by the owner, never by the requester — stranger-supplied text does
    /// not belong in a calendar title.
    public var meetingTitle: String
    public var meetingLocation: String?

    /// **Block for requests.** Events in these make the owner unavailable.
    /// Usually every real calendar.
    public var blocking: [CalRef]
    /// **Use for requests.** Accepted requests are written here. Exactly one.
    public var requestCalendar: CalRef?

    // MARK: Publish and poll state

    /// The fingerprint of what the service currently has, so a sync cycle that
    /// derived the same offers does not PUT them again. See `PublishPlanner`.
    public var lastPublishedFingerprint: String?
    public var lastPublishedAt: Date?
    /// The queue's weak ETag from the last poll, so an idle poll is a 304.
    public var queueETag: String?

    public init(slug: String = "", enabled: Bool = true,
                policy: RequestPolicy = RequestPolicy(),
                displayName: String = "", blurb: String? = nil,
                meetingTitle: String = "Meeting", meetingLocation: String? = nil,
                blocking: [CalRef] = [], requestCalendar: CalRef? = nil,
                lastPublishedFingerprint: String? = nil, lastPublishedAt: Date? = nil,
                queueETag: String? = nil) {
        self.slug = slug; self.enabled = enabled; self.policy = policy
        self.displayName = displayName; self.blurb = blurb
        self.meetingTitle = meetingTitle; self.meetingLocation = meetingLocation
        self.blocking = blocking; self.requestCalendar = requestCalendar
        self.lastPublishedFingerprint = lastPublishedFingerprint
        self.lastPublishedAt = lastPublishedAt
        self.queueETag = queueETag
    }

    /// Whether there is anything to publish or poll for. A page with no slug
    /// has not been created; one with no request calendar has nowhere to put
    /// an acceptance and must not offer times it cannot honour.
    public var isReady: Bool {
        enabled && !slug.isEmpty && requestCalendar != nil && !displayName.isEmpty
    }

    // Lenient decoding, as `Mirror` does it: a missing field is its default,
    // because a page that fails to parse is a page that silently stops
    // offering anything.
    enum CodingKeys: String, CodingKey {
        case slug, enabled, policy, displayName, blurb, meetingTitle, meetingLocation
        case blocking, requestCalendar, lastPublishedFingerprint, lastPublishedAt, queueETag
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        policy = (try? c.decode(RequestPolicy.self, forKey: .policy)) ?? RequestPolicy()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        blurb = try c.decodeIfPresent(String.self, forKey: .blurb)
        meetingTitle = try c.decodeIfPresent(String.self, forKey: .meetingTitle) ?? "Meeting"
        meetingLocation = try c.decodeIfPresent(String.self, forKey: .meetingLocation)
        blocking = (try? c.decode([CalRef].self, forKey: .blocking)) ?? []
        requestCalendar = try? c.decode(CalRef.self, forKey: .requestCalendar)
        lastPublishedFingerprint = try c.decodeIfPresent(String.self, forKey: .lastPublishedFingerprint)
        lastPublishedAt = (try? c.decode(String.self, forKey: .lastPublishedAt)).flatMap(ISO8601.date(from:))
        queueETag = try c.decodeIfPresent(String.self, forKey: .queueETag)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slug, forKey: .slug)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(policy, forKey: .policy)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(blurb, forKey: .blurb)
        try c.encode(meetingTitle, forKey: .meetingTitle)
        try c.encodeIfPresent(meetingLocation, forKey: .meetingLocation)
        try c.encode(blocking, forKey: .blocking)
        try c.encodeIfPresent(requestCalendar, forKey: .requestCalendar)
        try c.encodeIfPresent(lastPublishedFingerprint, forKey: .lastPublishedFingerprint)
        try c.encodeIfPresent(lastPublishedAt.map(ISO8601.string(from:)), forKey: .lastPublishedAt)
        try c.encodeIfPresent(queueETag, forKey: .queueETag)
    }
}

/// Where the write token lives. The Keychain in the apps; memory in tests.
public protocol TokenStore: Sendable {
    func token(for slug: String) throws -> String?
    func store(_ token: String, for slug: String) throws
    func remove(for slug: String) throws
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var tokens: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func token(for slug: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return tokens[slug] }
    public func store(_ token: String, for slug: String) throws { lock.lock(); defer { lock.unlock() }; tokens[slug] = token }
    public func remove(for slug: String) throws { lock.lock(); defer { lock.unlock() }; tokens[slug] = nil }
}
