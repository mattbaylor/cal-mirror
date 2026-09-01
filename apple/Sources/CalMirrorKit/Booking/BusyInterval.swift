import Foundation

/// One stretch of time the owner is not available, reduced to the three facts
/// derivation actually reads.
///
/// Deliberately not an `EKEvent`: title, location, attendees, calendar and
/// account are the things that must never reach the derivation, because
/// anything the deriver can see is something a future change could accidentally
/// publish. The engine adapts `EKEvent` into this at the boundary — the same
/// arrangement `FilterableEvent` uses, and for the same reason: it keeps the
/// whole rule set testable from `cmk-check` with no calendar and no Xcode.
public struct BusyInterval: Equatable, Sendable {
    public let start: Date
    public let end: Date
    /// All-day events have no meaningful time-of-day, so they block the whole
    /// local day rather than the instants their `start`/`end` happen to carry.
    /// EventKit is inconsistent about whether an all-day event ends at 23:59:59
    /// or at the following midnight, and treating one as a timed interval would
    /// mean the answer depends on which.
    public let isAllDay: Bool

    public init(start: Date, end: Date, isAllDay: Bool = false) {
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }
}

/// One offerable interval, in UTC.
///
/// Not "free time". A slot is an *offer* that has already survived every rule in
/// the policy, and the absence of one is not evidence of a meeting — it may be a
/// meeting, or a rule, or a nap. That ambiguity is the product's strongest
/// privacy property, and it exists because this type is all that gets published.
///
/// Its `Codable` conformance is the wire shape from
/// `askwhen/schema/policy-dump.schema.json` — `{"s": …, "e": …}`, ISO-8601 UTC —
/// rather than the property names, so the schema cannot drift away from the
/// encoder by accident.
public struct Slot: Equatable, Sendable, Codable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    enum CodingKeys: String, CodingKey { case s, e }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = try c.decode(String.self, forKey: .s)
        let e = try c.decode(String.self, forKey: .e)
        guard let start = ISO8601.date(from: s), let end = ISO8601.date(from: e) else {
            throw DecodingError.dataCorruptedError(forKey: .s, in: c,
                                                   debugDescription: "slot times must be ISO-8601 date-times")
        }
        self.start = start
        self.end = end
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ISO8601.string(from: start), forKey: .s)
        try c.encode(ISO8601.string(from: end), forKey: .e)
    }
}

/// ISO-8601 in UTC, formatted by the type rather than by whoever configured the
/// `JSONEncoder`. The dump is a published contract read by a browser that has
/// never heard of `JSONEncoder.DateEncodingStrategy`, so "somebody remembered to
/// set `.iso8601`" is not a strong enough guarantee to rest it on.
enum ISO8601 {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]   // no fractional seconds; slots land on minutes
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }

    static func date(from string: String) -> Date? {
        if let d = formatter.date(from: string) { return d }
        // Tolerate fractional seconds on the way in only. Nothing here writes
        // them, but a hand-edited or third-party document should not be rejected
        // over a detail the schema does not care about.
        let lenient = ISO8601DateFormatter()
        lenient.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return lenient.date(from: string)
    }
}
