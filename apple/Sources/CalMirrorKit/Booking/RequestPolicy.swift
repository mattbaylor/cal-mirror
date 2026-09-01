import Foundation

/// The owner's rules for what may be offered on their request page.
///
/// This never leaves the device — `PolicyDump` is the only thing that does, and
/// it carries the *result* of applying these rules, not the rules themselves.
/// That distinction is the whole privacy claim: a gap on the page could be a
/// meeting, a lunch break, a blackout date or a per-day cap, and nothing on the
/// wire says which.
///
/// The policy is inherently **local** — "my day starts at 9" means 9am where the
/// owner lives — so times are stored as wall-clock `HH:mm` strings plus an IANA
/// zone rather than as instants. Storing instants would bake today's UTC offset
/// into a rule that is supposed to outlive it.
///
/// Decoding is lenient in the same way `EventFilters` is: a bad field falls back
/// to its default rather than throwing, because a policy that fails to parse
/// means a page that silently stops offering anything.
public struct RequestPolicy: Codable, Equatable, Sendable {

    /// A weekday the owner is willing to be asked on. Spelled the way the design
    /// doc spells it (`"mon"`), not as a `Calendar` number, so the stored policy
    /// stays readable and does not depend on anyone's `firstWeekday`.
    public enum Weekday: String, Codable, Sendable, CaseIterable {
        case sun, mon, tue, wed, thu, fri, sat

        /// `Calendar`'s numbering, where Sunday is 1.
        public var calendarWeekday: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

        public static func from(calendarWeekday n: Int) -> Weekday? {
            allCases.indices.contains(n - 1) ? allCases[n - 1] : nil
        }
    }

    /// The owner's own day, as they would say it out loud. Both ends are
    /// wall-clock in `timeZone`; `ends` is exclusive — a slot must finish by then.
    public struct DayWindow: Codable, Equatable, Sendable {
        public var starts: String       // "09:00"
        public var ends: String         // "17:00"
        public init(starts: String = "09:00", ends: String = "17:00") {
            self.starts = starts; self.ends = ends
        }
    }

    /// A single mid-day gap to keep clear. One range, not many: the owner is
    /// answering "keep 12:00–1:30 clear", and a list of arbitrary exclusions is a
    /// second calendar wearing a disguise.
    public struct Lunch: Codable, Equatable, Sendable {
        public var from: String         // "12:00"
        public var to: String           // "13:30"
        public init(from: String = "12:00", to: String = "13:30") {
            self.from = from; self.to = to
        }
    }

    // MARK: Bounds

    /// The horizon bounds are product decisions, not preferences, so they live
    /// here as constants and the setter enforces them unconditionally.
    ///
    /// Below two days the page is empty more often than not and a request has no
    /// time to be collected and answered. Beyond 45 the slots are fiction —
    /// calendars fill, and offering March in January produces requests you will
    /// decline. The ceiling is also a privacy control: a longer horizon puts more
    /// of the owner's future shape on one screen.
    public static let horizonRange = 2...45
    public static let defaultHorizonDays = 14

    // Stored privately so the clamp cannot be routed around by assigning the
    // property directly. `horizonDays` is the only field where an out-of-range
    // value is a correctness problem rather than a merely odd choice.
    private var storedHorizonDays: Int

    public var horizonDays: Int {
        get { storedHorizonDays }
        set { storedHorizonDays = Self.clampHorizon(newValue) }
    }

    public static func clampHorizon(_ days: Int) -> Int {
        min(horizonRange.upperBound, max(horizonRange.lowerBound, days))
    }

    // MARK: Rules

    /// How long before a slot may be asked for. Guards against a request landing
    /// with less warning than the owner's device needs to collect it.
    public var minNoticeHours: Int
    /// Length of one offer, in minutes. Meeting length and slot length are the
    /// same number here; the dump carries it again as `meeting.minutes`.
    public var slotMinutes: Int
    /// Slots start on a multiple of this many minutes past the hour — 30 gives
    /// `:00`/`:30`, never `:07`. Values that do not divide 60 still produce a
    /// consistent grid but one that walks through the hour, which is why the
    /// picker should only ever offer divisors.
    public var align: Int
    /// Kept clear either side of a real event, so a request can't land wheel-to-
    /// wheel against a meeting the requester cannot see.
    public var bufferMinutes: Int
    /// Ceiling on offers per day. This matters more than it looks: publishing
    /// every free half-hour tells a stranger your week is empty, and offering
    /// four says nothing about the other twelve.
    public var maxPerDay: Int

    public var day: DayWindow
    public var lunch: Lunch?
    public var weekdays: [Weekday]

    /// Dates the owner is not available at all, as `yyyy-MM-dd` in `timeZone`.
    /// Stored as strings for the same reason the day window is: a blackout is a
    /// date on a wall calendar, not an instant.
    public var blackout: [String]

    /// IANA identifier. Stated explicitly rather than inferred from the device,
    /// because a laptop that travels must not quietly re-interpret "my day
    /// starts at 9".
    public var timeZone: String

    public init(horizonDays: Int = RequestPolicy.defaultHorizonDays,
                minNoticeHours: Int = 12,
                slotMinutes: Int = 30,
                align: Int = 30,
                bufferMinutes: Int = 15,
                maxPerDay: Int = 4,
                day: DayWindow = DayWindow(),
                lunch: Lunch? = nil,
                weekdays: [Weekday] = [.mon, .tue, .wed, .thu, .fri],
                blackout: [String] = [],
                timeZone: String = TimeZone.current.identifier) {
        self.storedHorizonDays = Self.clampHorizon(horizonDays)
        self.minNoticeHours = max(0, minNoticeHours)
        self.slotMinutes = max(1, slotMinutes)
        self.align = max(1, min(60, align))
        self.bufferMinutes = max(0, bufferMinutes)
        self.maxPerDay = max(0, maxPerDay)
        self.day = day
        self.lunch = lunch
        self.weekdays = weekdays
        self.blackout = blackout
        self.timeZone = timeZone
    }

    // MARK: Derived

    /// `nil` when `timeZone` names a zone this system does not know.
    ///
    /// `SlotDeriver` offers nothing at all in that case rather than falling back
    /// to the device's own zone. An empty page is a visible failure the owner can
    /// act on; a page full of slots at the wrong hour is an invisible one their
    /// requesters discover for them.
    public var resolvedTimeZone: TimeZone? { TimeZone(identifier: timeZone) }

    /// The weekday set as `Calendar` numbers, for the derivation loop.
    var allowedCalendarWeekdays: Set<Int> { Set(weekdays.map(\.calendarWeekday)) }

    var blackoutDates: Set<String> { Set(blackout) }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case horizonDays, minNoticeHours, slotMinutes, align, bufferMinutes, maxPerDay
        case day, lunch, weekdays, blackout, timeZone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RequestPolicy()
        storedHorizonDays = Self.clampHorizon((try? c.decode(Int.self, forKey: .horizonDays)) ?? d.horizonDays)
        minNoticeHours = max(0, (try? c.decode(Int.self, forKey: .minNoticeHours)) ?? d.minNoticeHours)
        slotMinutes = max(1, (try? c.decode(Int.self, forKey: .slotMinutes)) ?? d.slotMinutes)
        align = max(1, min(60, (try? c.decode(Int.self, forKey: .align)) ?? d.align))
        bufferMinutes = max(0, (try? c.decode(Int.self, forKey: .bufferMinutes)) ?? d.bufferMinutes)
        maxPerDay = max(0, (try? c.decode(Int.self, forKey: .maxPerDay)) ?? d.maxPerDay)
        day = (try? c.decode(DayWindow.self, forKey: .day)) ?? d.day
        lunch = try? c.decode(Lunch.self, forKey: .lunch)
        // An unrecognised weekday name is dropped rather than throwing, but an
        // entirely unparseable list falls back to the default working week — a
        // silently empty week would look exactly like "nobody wants to meet you".
        if let raw = try? c.decode([String].self, forKey: .weekdays) {
            weekdays = raw.compactMap { Weekday(rawValue: $0.lowercased()) }
        } else {
            weekdays = d.weekdays
        }
        blackout = (try? c.decode([String].self, forKey: .blackout)) ?? []
        timeZone = (try? c.decode(String.self, forKey: .timeZone)) ?? d.timeZone
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(horizonDays, forKey: .horizonDays)
        try c.encode(minNoticeHours, forKey: .minNoticeHours)
        try c.encode(slotMinutes, forKey: .slotMinutes)
        try c.encode(align, forKey: .align)
        try c.encode(bufferMinutes, forKey: .bufferMinutes)
        try c.encode(maxPerDay, forKey: .maxPerDay)
        try c.encode(day, forKey: .day)
        try c.encodeIfPresent(lunch, forKey: .lunch)
        try c.encode(weekdays.map(\.rawValue), forKey: .weekdays)
        try c.encode(blackout, forKey: .blackout)
        try c.encode(timeZone, forKey: .timeZone)
    }
}

// MARK: - Wall-clock helpers

extension RequestPolicy {
    /// `"09:30"` → 570 minutes past midnight. Returns nil for anything that is
    /// not a plain `HH:mm`, which the caller treats as "the window is unusable"
    /// rather than guessing at an hour on the owner's behalf.
    ///
    /// 24:00 is accepted as an end so "my day ends at midnight" is expressible.
    static func minutesPastMidnight(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...24).contains(h), (0...59).contains(m), h * 60 + m <= 24 * 60 else { return nil }
        return h * 60 + m
    }
}
