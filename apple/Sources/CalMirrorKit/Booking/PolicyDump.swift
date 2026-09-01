import Foundation

/// The ONLY artifact that leaves the owner's device.
///
/// Its shape is fixed by `askwhen/schema/policy-dump.schema.json`, which is
/// written to *forbid*: `additionalProperties: false` at every level, so a field
/// added here in passing is a schema failure rather than a quiet disclosure.
/// That is the point of the schema, and the reason this type encodes an explicit
/// key list instead of leaning on synthesis — synthesis would happily publish
/// whatever stored property somebody adds next.
///
/// What is absent is absent on purpose:
///
/// - **No busy blocks.** They leak the shape of a day — when it starts, where
///   lunch is, how dense it is, that 2am call. Offers leak only the offer.
/// - **No titles, locations, attendees, calendar or account names.** Never
///   derived, so never available to publish.
/// - **No owner email.** The service must not be able to reach the owner; it has
///   nowhere to send. That is the design, not an oversight.
/// - **No free/busy outside offer hours.** A gap on the page may be a meeting or
///   may be a rule, and the page cannot tell which because the device collapsed
///   the two before uploading.
///
/// `display.name` is the single identifying field in the whole document, chosen
/// by the owner in the knowledge that it is public.
public struct PolicyDump: Equatable, Sendable, Codable {

    /// The schema's ceiling. A fortnight of half-hour slots inside working hours
    /// is ~150 entries, so this only bites on a long horizon with a high cap —
    /// and truncating is better than publishing a document the page will refuse.
    public static let maxSlots = 500

    public struct Display: Equatable, Sendable, Codable {
        /// Required. A stranger arriving cold from a link needs to know they
        /// reached the person they meant, and an unnamed page asking for an email
        /// address looks like a phishing form. Free text, so the owner decides
        /// how much they are disclosing: "Matt Baylor", "Matt B" and "The Referee
        /// Guy" are all valid answers.
        public var name: String
        public var blurb: String?
        /// IANA zone — only so the page can show the owner's local time beside
        /// the requester's. It is not used to interpret any slot; those are UTC.
        public var tz: String

        public init(name: String, blurb: String? = nil, tz: String) {
            self.name = name; self.blurb = blurb; self.tz = tz
        }

        enum CodingKeys: String, CodingKey { case name, blurb, tz }
    }

    public struct Meeting: Equatable, Sendable, Codable {
        public var minutes: Int
        /// Set by the owner, never by the requester — stranger-supplied text does
        /// not belong in someone's calendar title. The requester's note goes in
        /// the body, where it is obviously theirs.
        public var title: String
        public var location: String?

        public init(minutes: Int, title: String, location: String? = nil) {
            self.minutes = minutes; self.title = title; self.location = location
        }

        enum CodingKeys: String, CodingKey { case minutes, title, location }
    }

    /// Schema `const: 1`. Not settable, and written unconditionally.
    public let v = 1
    public var slug: String
    public var generated: Date
    /// After this the service stops serving the dump, so a device that goes quiet
    /// cannot leave stale availability up forever.
    public var expires: Date
    public var display: Display
    public var meeting: Meeting
    public var slots: [Slot]

    public init(slug: String, generated: Date, expires: Date,
                display: Display, meeting: Meeting, slots: [Slot]) {
        self.slug = slug
        self.generated = generated
        self.expires = expires
        self.display = display
        self.meeting = meeting
        self.slots = Array(slots.prefix(Self.maxSlots))
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey { case v, slug, generated, expires, display, meeting, slots }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        display = try c.decode(Display.self, forKey: .display)
        meeting = try c.decode(Meeting.self, forKey: .meeting)
        slots = try c.decode([Slot].self, forKey: .slots)
        let g = try c.decode(String.self, forKey: .generated)
        let e = try c.decode(String.self, forKey: .expires)
        guard let generated = ISO8601.date(from: g), let expires = ISO8601.date(from: e) else {
            throw DecodingError.dataCorruptedError(forKey: .generated, in: c,
                                                   debugDescription: "generated/expires must be ISO-8601 date-times")
        }
        self.generated = generated
        self.expires = expires
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(slug, forKey: .slug)
        try c.encode(ISO8601.string(from: generated), forKey: .generated)
        try c.encode(ISO8601.string(from: expires), forKey: .expires)
        try c.encode(display, forKey: .display)
        try c.encode(meeting, forKey: .meeting)
        try c.encode(slots, forKey: .slots)
    }

    /// The bytes that go on the wire. Sorted keys so the content hash in §3a
    /// compares two dumps by what they *say* rather than by what order a
    /// dictionary happened to iterate in — otherwise "publish only on change"
    /// would republish at random.
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    // MARK: Validation

    /// Everything the schema asserts that Swift's type system does not, listed
    /// rather than thrown so a caller can log all of it at once.
    ///
    /// This is a belt on top of the schema's braces: the service will reject an
    /// invalid dump, but the device finding out first means the owner gets told
    /// instead of their page quietly going dark.
    public var validationProblems: [String] {
        var problems: [String] = []
        if slug.range(of: "^[a-z0-9]{6,32}$", options: .regularExpression) == nil {
            problems.append("slug must match ^[a-z0-9]{6,32}$")
        }
        if display.name.isEmpty || display.name.count > 60 {
            problems.append("display.name must be 1–60 characters")
        }
        if let blurb = display.blurb, blurb.count > 200 {
            problems.append("display.blurb must be at most 200 characters")
        }
        if display.tz.isEmpty { problems.append("display.tz must name an IANA zone") }
        if !(5...480).contains(meeting.minutes) { problems.append("meeting.minutes must be 5–480") }
        if meeting.title.isEmpty || meeting.title.count > 80 {
            problems.append("meeting.title must be 1–80 characters")
        }
        if let location = meeting.location, location.count > 200 {
            problems.append("meeting.location must be at most 200 characters")
        }
        if slots.count > Self.maxSlots { problems.append("slots must be at most \(Self.maxSlots)") }
        if slots.contains(where: { $0.end <= $0.start }) { problems.append("every slot must end after it starts") }
        return problems
    }

    public var isSchemaValid: Bool { validationProblems.isEmpty }
}
