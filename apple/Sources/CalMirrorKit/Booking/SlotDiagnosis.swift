import Foundation

/// Why a candidate was not offered — and never *what* rejected it.
///
/// The whole point of this type is what it cannot carry. There is no associated
/// value, no event, no title, no attendee, no calendar name. A diagnosis is
/// counts, so "twelve slots were blocked" can be said out loud on a surface the
/// owner is talking to without the thing doing the talking learning anything
/// about the owner's week beyond what they already know.
///
/// That matters because the intended readers are an MCP server and Siri
/// (`askwhen/design/mcp.md`, `siri.md`), which means anything returned here
/// leaves the device. Counts are the owner disclosing their own availability
/// shape, in a session they started. Event details would be something else.
public enum Rejection: String, Sendable, CaseIterable, Codable {
    /// The wall-clock time does not exist — the hour spring-forward deletes.
    case clockSkipped
    /// The slot would run past the end of the owner's day.
    case pastDayEnd
    /// Inside `minNoticeHours` of now.
    case minimumNotice
    /// Overlaps the lunch window.
    case lunch
    /// Overlaps a timed event on a blocking calendar, plus its buffer.
    case busy
    /// Survived every rule and was then thinned out by `maxPerDay`.
    ///
    /// Worth separating from the rest: these are slots the owner *could* have
    /// offered and chose not to, which is a very different answer to "why is
    /// nothing showing" than "you were busy".
    case cappedPerDay
}

/// Encoding `[Rejection: Int]` as a JSON *object* rather than as the flat
/// alternating array Swift produces by default for non-string dictionary keys.
///
/// The eventual readers are an MCP tool and an App Intent, both of which will
/// hand this to a model. `{"busy": 12, "minimumNotice": 2}` is self-describing;
/// `["busy", 12, "minimumNotice", 2]` is a puzzle, and a model asked to read a
/// puzzle will occasionally read it wrong.
extension Rejection: CodingKeyRepresentable {
    public var codingKey: CodingKey { RejectionKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}

struct RejectionKey: CodingKey {
    var stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

/// Why a whole day offered nothing, before any slot was considered.
public enum DayRejection: String, Sendable, Codable {
    case weekdayNotOffered
    case blackoutDate
    /// An all-day event on a blocking calendar covers the day.
    case allDayEvent
    /// The calendar could not resolve the day or its closing time. Should not
    /// happen for a valid zone; recorded rather than silently skipped so that
    /// "the numbers do not add up" is never the first sign of it.
    case dayUnavailable
}

/// Why the policy produced nothing at all, whatever the calendar said.
public enum PolicyProblem: String, Sendable, Codable {
    case unknownTimeZone
    case dayWindowInvalid
    case maxPerDayNotPositive
}

/// One local day's accounting.
///
/// The invariant worth knowing: `offered` plus every rejection count equals
/// `considered`. Each grid position is attributed to exactly one outcome, so the
/// numbers always add up — which is what makes the output checkable rather than
/// merely plausible.
public struct DayDiagnosis: Sendable, Codable {
    /// Local calendar day, `yyyy-MM-dd`, in the owner's zone.
    public let day: String
    public let offered: Int
    public let considered: Int
    public let rejections: [Rejection: Int]
    /// Set when the day was excluded outright; then `considered` is zero.
    public let dayRejection: DayRejection?

    /// Rejections in a stable order, zero counts dropped.
    ///
    /// A dictionary iterates arbitrarily, and a diagnosis that lists reasons in
    /// a different order each time reads like a different answer each time.
    public var orderedRejections: [(Rejection, Int)] {
        Rejection.allCases.compactMap { r in
            guard let n = rejections[r], n > 0 else { return nil }
            return (r, n)
        }
    }
}

/// What `SlotDeriver.explain` returns.
public struct Diagnosis: Sendable, Codable {
    /// Set when the policy itself is why there are no offers. `days` is then empty.
    public let policyProblem: PolicyProblem?
    public let days: [DayDiagnosis]

    public var totalOffered: Int { days.reduce(0) { $0 + $1.offered } }

    /// The days that offered nothing, which is the question people actually ask.
    public var emptyDays: [DayDiagnosis] { days.filter { $0.offered == 0 } }
}
