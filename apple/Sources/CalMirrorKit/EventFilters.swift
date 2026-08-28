import Foundation

/// Per-mirror event selection by the source event's OWN properties — as opposed
/// to `TagFilter`, which selects on `#tags` you hand-write into the notes. Tags
/// only work on events you author; these rules work on a calendar you don't
/// control (a subscribed work feed, a team calendar, an assigned-games feed).
///
/// Every key names what it SKIPS, so an absent block, or one left at its
/// defaults, selects nothing away — the historical behavior of copying every
/// event. That's the same contract `projection` and `tagFilter` honor.
///
/// Pure by design (no EventKit): `MirrorEngine` adapts each `EKEvent` into a
/// `FilterableEvent` and calls `admits`, so every rule here is unit-testable
/// from `cmk-check` with no Xcode and no calendar access.
public struct EventFilters: Codable, Equatable, Sendable {

    // MARK: Invitation state

    /// Skip events the user has declined. A declined meeting mirrored as a solid
    /// busy block is the single most-reported wrong copy.
    public var declined: Bool
    /// Skip invitations the user hasn't answered yet.
    public var unanswered: Bool
    /// Skip events the organizer has canceled but that linger in the feed.
    public var canceled: Bool

    // MARK: Shape

    /// Skip all-day events (birthdays, holidays, OOO banners).
    public var allDay: Bool
    /// Skip events whose source availability is `free` — they don't block time.
    public var free: Bool

    /// Skip events shorter than this many minutes. 0 = off.
    public var shorterThanMinutes: Int
    /// Skip events longer than this many minutes. 0 = off.
    public var longerThanMinutes: Int

    // MARK: Content and time

    public var title: TitleRule?
    public var hours: HoursRule?

    /// Substring match on the source title. One `mode`, so "include and reject
    /// at once" stays unrepresentable — the same shape `TagFilter` uses.
    public struct TitleRule: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable { case include, reject }
        public var mode: Mode
        /// Case-insensitive substrings, not regex: a regex in a text field is a
        /// support burden, and every competitor that exposes one does it in YAML.
        public var patterns: [String]

        public init(mode: Mode, patterns: [String]) { self.mode = mode; self.patterns = patterns }

        /// Lenient in the same direction as `TagFilter`: a missing/unknown `mode`
        /// THROWS so the enclosing optional decodes to nil — no rule at all,
        /// never a half-set one that silently drops events.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decode(Mode.self, forKey: .mode)
            patterns = (try? c.decode([String].self, forKey: .patterns)) ?? []
        }

        public var isActive: Bool { patterns.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

        public func admits(title: String) -> Bool {
            guard isActive else { return true }
            let hay = title.lowercased()
            let hit = patterns.contains { p in
                let needle = p.trimmingCharacters(in: .whitespaces).lowercased()
                return !needle.isEmpty && hay.contains(needle)
            }
            return mode == .include ? hit : !hit
        }
    }

    /// Time-of-day / day-of-week window. `keep` copies only what overlaps the
    /// window; `drop` copies only what falls entirely outside it.
    public struct HoursRule: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable { case keep, drop }
        public var mode: Mode
        /// Minutes from midnight, local. `start < end` is a same-day window;
        /// `start > end` wraps midnight (e.g. 22:00–06:00 for overnight on-call).
        public var startMinute: Int
        public var endMinute: Int
        /// Weekdays the window applies on, `Calendar` numbering (1 = Sunday).
        /// Empty = every day.
        public var days: [Int]

        public init(mode: Mode, startMinute: Int, endMinute: Int, days: [Int] = []) {
            self.mode = mode; self.startMinute = startMinute
            self.endMinute = endMinute; self.days = days
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decode(Mode.self, forKey: .mode)
            startMinute = Self.minutes(try? c.decode(String.self, forKey: .start)) ?? 0
            endMinute = Self.minutes(try? c.decode(String.self, forKey: .end)) ?? 24 * 60
            days = ((try? c.decode([Int].self, forKey: .days)) ?? []).filter { (1...7).contains($0) }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(mode, forKey: .mode)
            try c.encode(Self.hhmm(startMinute), forKey: .start)
            try c.encode(Self.hhmm(endMinute), forKey: .end)
            try c.encode(days, forKey: .days)
        }

        enum CodingKeys: String, CodingKey { case mode, start, end, days }

        /// "08:00" → 480. Stored as HH:mm in JSON so the file stays hand-editable.
        static func minutes(_ s: String?) -> Int? {
            guard let s else { return nil }
            let parts = s.split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
                  (0...24).contains(h), (0...59).contains(m) else { return nil }
            return h * 60 + m
        }
        static func hhmm(_ mins: Int) -> String {
            String(format: "%02d:%02d", (mins / 60) % 25, mins % 60)
        }

        /// A window covering the whole day on every weekday constrains nothing.
        public var isActive: Bool {
            !(startMinute == 0 && endMinute >= 24 * 60 && days.isEmpty)
        }

        /// The window as one or two half-open minute ranges within a single day.
        /// A window that wraps past midnight (22:00–06:00) becomes two.
        var dayIntervals: [(start: Int, end: Int)] {
            if startMinute <= endMinute { return [(startMinute, endMinute)] }
            return [(startMinute, 24 * 60), (0, endMinute)]
        }

        /// True if `minute` (from midnight) falls inside the window.
        func containsMinute(_ minute: Int) -> Bool {
            dayIntervals.contains { minute >= $0.start && minute < $0.end }
        }
    }

    public init(declined: Bool = false, unanswered: Bool = false, canceled: Bool = false,
                allDay: Bool = false, free: Bool = false,
                shorterThanMinutes: Int = 0, longerThanMinutes: Int = 0,
                title: TitleRule? = nil, hours: HoursRule? = nil) {
        self.declined = declined; self.unanswered = unanswered; self.canceled = canceled
        self.allDay = allDay; self.free = free
        self.shorterThanMinutes = shorterThanMinutes; self.longerThanMinutes = longerThanMinutes
        self.title = title; self.hours = hours
    }

    // Fully lenient: any bad or absent field falls back to its default, and a
    // malformed value never throws (which would nuke the whole config).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        declined = (try? c.decode(Bool.self, forKey: .declined)) ?? false
        unanswered = (try? c.decode(Bool.self, forKey: .unanswered)) ?? false
        canceled = (try? c.decode(Bool.self, forKey: .canceled)) ?? false
        allDay = (try? c.decode(Bool.self, forKey: .allDay)) ?? false
        free = (try? c.decode(Bool.self, forKey: .free)) ?? false
        shorterThanMinutes = max(0, (try? c.decode(Int.self, forKey: .shorterThanMinutes)) ?? 0)
        longerThanMinutes = max(0, (try? c.decode(Int.self, forKey: .longerThanMinutes)) ?? 0)
        title = try? c.decode(TitleRule.self, forKey: .title)
        hours = try? c.decode(HoursRule.self, forKey: .hours)
    }

    /// Does this block actually constrain anything? Drives the UI's "N rules"
    /// summary and lets `saveConfig` omit an all-default block from the JSON.
    public var activeRuleCount: Int {
        var n = 0
        for flag in [declined, unanswered, canceled, allDay, free] where flag { n += 1 }
        if shorterThanMinutes > 0 { n += 1 }
        if longerThanMinutes > 0 { n += 1 }
        if title?.isActive == true { n += 1 }
        if hours?.isActive == true { n += 1 }
        return n
    }
    public var isActive: Bool { activeRuleCount > 0 }
}

/// The slice of an event the filters actually read. `MirrorEngine` builds one
/// per source event from `EKEvent`; `cmk-check` builds them by hand.
public struct FilterableEvent: Sendable, Equatable {
    /// The user's own reply to an invitation. `none` covers an event with no
    /// attendees at all — a block you made for yourself is neither accepted nor
    /// pending, so `unanswered` must never eat it.
    public enum Reply: String, Sendable { case none, accepted, declined, pending }

    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let isFree: Bool
    public let isCanceled: Bool
    public let reply: Reply

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false,
                isFree: Bool = false, isCanceled: Bool = false, reply: Reply = .none) {
        self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.isFree = isFree
        self.isCanceled = isCanceled; self.reply = reply
    }

    public var durationMinutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
}

extension EventFilters {
    /// The copy(true)/skip(false) verdict for one source event.
    ///
    /// `calendar` resolves time-of-day in the user's own locale and timezone —
    /// "my evenings" means the user's evenings, not the event's originating zone.
    public func admits(_ ev: FilterableEvent, calendar: Calendar = .current) -> Bool {
        if canceled && ev.isCanceled { return false }
        if declined && ev.reply == .declined { return false }
        if unanswered && ev.reply == .pending { return false }
        if allDay && ev.isAllDay { return false }
        if free && ev.isFree { return false }

        // Duration uses the source's real span, before any projection.
        if shorterThanMinutes > 0 && ev.durationMinutes < shorterThanMinutes { return false }
        if longerThanMinutes > 0 && ev.durationMinutes > longerThanMinutes { return false }

        if let t = title, !t.admits(title: ev.title) { return false }

        if let h = hours, h.isActive {
            // All-day events have no time-of-day, so a time window can't speak to
            // them. Dropping them here would silently eat every birthday from a
            // "work hours only" mirror; `allDay` is the switch for that.
            if !ev.isAllDay {
                let overlaps = Self.overlapsWindow(ev, h, calendar: calendar)
                if h.mode == .keep && !overlaps { return false }
                if h.mode == .drop && overlaps { return false }
            }
        }
        return true
    }

    /// Does the event touch the window on any day it spans? Overlap-based, not
    /// containment: a 7–9am event against an 8am–6pm keep-window is kept, because
    /// part of it is inside working hours. Containment would surprise anyone with
    /// a meeting that starts before the window opens.
    static func overlapsWindow(_ ev: FilterableEvent, _ h: HoursRule, calendar: Calendar) -> Bool {
        // Walk each calendar day the event touches (bounded — a multi-week event
        // still only needs a handful of iterations before it must have hit the
        // window on some allowed weekday).
        var day = calendar.startOfDay(for: ev.start)
        let lastDay = calendar.startOfDay(for: max(ev.start, ev.end))
        var guardCount = 0
        while day <= lastDay && guardCount < 400 {
            guardCount += 1
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400) }

            let weekday = calendar.component(.weekday, from: day)
            if !h.days.isEmpty && !h.days.contains(weekday) { continue }

            // The event's span within this particular day, in minutes from midnight.
            let dayEnd = day.addingTimeInterval(86400)
            let sliceStart = max(ev.start, day), sliceEnd = min(ev.end, dayEnd)
            if sliceEnd <= sliceStart {
                // Zero-length event exactly at a boundary — treat as a point in time.
                if ev.start == ev.end, ev.start >= day, ev.start < dayEnd,
                   h.containsMinute(Int(ev.start.timeIntervalSince(day) / 60)) { return true }
                continue
            }
            let from = Int(sliceStart.timeIntervalSince(day) / 60)
            let to = max(from + 1, Int(ceil(sliceEnd.timeIntervalSince(day) / 60)))
            for w in h.dayIntervals where from < w.end && to > w.start { return true }
        }
        return false
    }
}
