import Foundation

/// Busy time plus a policy in, offerable slots out. Nothing else.
///
/// This is where the privacy claim is made. Everything downstream just moves the
/// resulting file around, so every rule that decides what a stranger may see
/// lives in this one pure function — no EventKit, no network, no clock of its
/// own. `now` is a parameter for the same reason `SyncScheduler` takes one:
/// `cmk-check` needs to drive it through a March and a November it will never
/// actually be running on.
///
/// ## The one thing that must not go wrong
///
/// Derivation walks **local days** and converts each slot at that day's own UTC
/// offset. It never advances a UTC instant by 86400 seconds, because the week a
/// clock changes one local day is 23 or 25 hours long and a naive loop shifts
/// every slot after it by an hour — silently, plausibly, and only for the people
/// looking at the page. `Calendar.date(byAdding: .day, …)` and
/// `Calendar.date(from: DateComponents)` both do the right thing here; arithmetic
/// on `TimeInterval` does not.
///
/// Durations, by contrast, *are* absolute: a 30-minute meeting is 30 real
/// minutes whatever the clocks are doing, so slot ends are the only place
/// interval arithmetic is correct.
public enum SlotDeriver {

    public static func derive(policy: RequestPolicy, busy: [BusyInterval], now: Date) -> [Slot] {
        // An unknown zone means no offers at all. See `resolvedTimeZone`: an
        // empty page is a failure the owner can see, a page at the wrong hour is
        // one only their requesters find out about.
        guard let zone = policy.resolvedTimeZone else { return [] }
        guard let dayStartMin = RequestPolicy.minutesPastMidnight(policy.day.starts),
              let dayEndMin = RequestPolicy.minutesPastMidnight(policy.day.ends),
              dayEndMin > dayStartMin,
              policy.maxPerDay > 0 else { return [] }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone

        let notBefore = now.addingTimeInterval(TimeInterval(policy.minNoticeHours) * 3600)
        let slotSeconds = TimeInterval(policy.slotMinutes) * 60
        let buffer = TimeInterval(policy.bufferMinutes) * 60
        let allowedWeekdays = policy.allowedCalendarWeekdays
        let blackout = policy.blackoutDates

        // Busy intervals are split once, up front: all-day events are answered by
        // "does this day touch them", timed events by an overlap test against a
        // buffered span. Doing it here keeps the per-slot loop cheap and keeps the
        // buffer from being applied twice.
        let allDayBusy = busy.filter(\.isAllDay)
        let timedBusy = busy.filter { !$0.isAllDay }.map {
            (start: $0.start.addingTimeInterval(-buffer), end: $0.end.addingTimeInterval(buffer))
        }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = cal
        dayFormatter.timeZone = zone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let firstDay = cal.startOfDay(for: now)
        var offers: [Slot] = []

        for dayIndex in 0..<policy.horizonDays {
            guard let midnight = cal.date(byAdding: .day, value: dayIndex, to: firstDay) else { continue }
            // Re-normalising matters in the handful of zones whose transition
            // happens *at* midnight, where "same wall time, next day" is not the
            // start of that day.
            let day = cal.startOfDay(for: midnight)

            guard allowedWeekdays.contains(cal.component(.weekday, from: day)) else { continue }
            guard !blackout.contains(dayFormatter.string(from: day)) else { continue }

            let nextMidnight = cal.date(byAdding: .day, value: 1, to: day).map { cal.startOfDay(for: $0) }
                ?? day.addingTimeInterval(25 * 3600)
            // An all-day event blocks the day it *covers*, half-open at both ends
            // so an event ending at the following midnight does not eat a second
            // day. This is the whole reason `isAllDay` is carried across the
            // boundary rather than inferred from the timestamps.
            if allDayBusy.contains(where: { $0.start < nextMidnight && $0.end > day }) { continue }

            guard let dayEnds = wallClock(dayEndMin, on: day, cal: cal) else { continue }

            var candidates: [Slot] = []
            var minute = firstAlignedMinute(atOrAfter: dayStartMin, align: policy.align)
            while minute + policy.slotMinutes <= dayEndMin {
                defer { minute += policy.align }

                // A wall-clock time that does not exist — the hour spring-forward
                // deletes — has no instant to offer, so it is skipped rather than
                // silently rounded into the hour either side of the gap.
                guard let start = wallClock(minute, on: day, cal: cal, requireExact: true) else { continue }
                let end = start.addingTimeInterval(slotSeconds)

                // Checked as instants, not as wall-clock minutes, so a slot can
                // never run past the owner's day on a 25-hour one.
                if end > dayEnds { continue }
                if start < notBefore { continue }
                if let lunch = policy.lunch, overlapsLunch(start: start, end: end, lunch: lunch, day: day, cal: cal) { continue }
                if timedBusy.contains(where: { start < $0.end && end > $0.start }) { continue }

                candidates.append(Slot(start: start, end: end))
            }

            offers.append(contentsOf: spread(candidates, cap: policy.maxPerDay))
        }

        return offers
    }

    // MARK: - Pieces

    /// The first slot start at or after the day window opens that still lands on
    /// the alignment grid. Aligning from midnight rather than from `day.starts`
    /// is what makes a 9:15 start produce 9:30 slots instead of 9:15 ones.
    static func firstAlignedMinute(atOrAfter minute: Int, align: Int) -> Int {
        let remainder = minute % align
        return remainder == 0 ? minute : minute + (align - remainder)
    }

    /// A wall-clock minute-past-midnight resolved against a specific local day.
    ///
    /// `requireExact` asks whether the instant we got back really is the time we
    /// asked for. `Calendar` will happily hand back a nearby instant for a time
    /// the clock skipped, which is the right behaviour for a reminder and the
    /// wrong one for an offer — nobody can meet you at 2:30am on the morning
    /// 2:30am did not happen.
    static func wallClock(_ minute: Int, on day: Date, cal: Calendar, requireExact: Bool = false) -> Date? {
        // Minute 1440 is "the end of this day", which as components belongs to
        // the next one — and asking for hour 24 gets nothing back.
        if minute >= 24 * 60 {
            return cal.date(byAdding: .day, value: 1, to: day).map { cal.startOfDay(for: $0) }
        }
        var parts = cal.dateComponents([.year, .month, .day], from: day)
        parts.hour = minute / 60
        parts.minute = minute % 60
        guard let date = cal.date(from: parts) else { return nil }
        guard requireExact else { return date }
        let back = cal.dateComponents([.hour, .minute], from: date)
        return (back.hour == parts.hour && back.minute == parts.minute) ? date : nil
    }

    static func overlapsLunch(start: Date, end: Date, lunch: RequestPolicy.Lunch,
                              day: Date, cal: Calendar) -> Bool {
        guard let fromMin = RequestPolicy.minutesPastMidnight(lunch.from),
              let toMin = RequestPolicy.minutesPastMidnight(lunch.to),
              toMin > fromMin,
              let from = wallClock(fromMin, on: day, cal: cal),
              let to = wallClock(toMin, on: day, cal: cal) else { return false }
        return start < to && end > from
    }

    /// Thin `candidates` down to at most `cap`, taken evenly across the day
    /// rather than off the front.
    ///
    /// Front-loading would be a disclosure in itself: four consecutive morning
    /// slots say "and then the afternoon filled up", where four spread across the
    /// day say nothing about the twenty they were chosen from. Keeping the first
    /// and last is deliberate too — the shape of the offer should match the shape
    /// of the day the owner described.
    static func spread(_ candidates: [Slot], cap: Int) -> [Slot] {
        guard cap > 0 else { return [] }
        guard candidates.count > cap else { return candidates }
        if cap == 1 { return [candidates[0]] }

        var picked: [Slot] = []
        var lastIndex = -1
        let last = Double(candidates.count - 1)
        for i in 0..<cap {
            let index = Int((Double(i) * last / Double(cap - 1)).rounded())
            // Rounding can land twice on the same slot when the list is barely
            // longer than the cap; stepping forward keeps the count honest.
            let next = max(index, lastIndex + 1)
            guard next < candidates.count else { break }
            picked.append(candidates[next])
            lastIndex = next
        }
        return picked
    }
}
