import Foundation

/// "When are you free?" answered as a line of text: the next few offerable
/// times, in the owner's zone, and the page's link after them if there is
/// one. No service is involved — the slots are `SlotDeriver`'s, from the same
/// policy and the same busy shape the page is built from, so what the text
/// offers and what the page offers can never disagree.
///
/// ```
/// Tue 2–2:30pm, Wed 10–10:30am or Thu 3–3:30pm MDT — or pick one: askwhen.me/k9x2f
/// ```
///
/// Three reads as an offer and eight as a timetable, so `pick` takes the
/// earliest slot on each of the next days that offer one, and only fills a
/// day twice when there are not enough days. The zone is the owner's and is
/// said once; the app cannot know the recipient's, and a guess stated as a
/// fact is worse than one honest zone. Both are `decisions.md`, *Inside
/// "Send times"*. Pure, like the deriver: `now` and the locale are
/// parameters so `cmk-check` can drive it through a fall-back day and a
/// 24-hour locale it will never run in.
public enum SendTimes {

    /// One per day first, earliest on each, then the next on days already
    /// used. Returns in chronological order.
    public static func pick(_ slots: [Slot], count: Int = 3, zone: TimeZone) -> [Slot] {
        guard count > 0, !slots.isEmpty else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var chosen: [Slot] = []
        var days = Set<DateComponents>()
        for s in slots where chosen.count < count {
            let day = cal.dateComponents([.year, .month, .day], from: s.start)
            if days.insert(day).inserted { chosen.append(s) }
        }
        if chosen.count < count {
            for s in slots where chosen.count < count && !chosen.contains(s) { chosen.append(s) }
        }
        return chosen.sorted { $0.start < $1.start }
    }

    /// The line. `link` is the page's address without a scheme, or nil for an
    /// owner with no page; the text is then the times alone, which is still
    /// the whole reason for the feature.
    public static func text(_ picks: [Slot], zone: TimeZone, link: String?,
                            now: Date = Date(), locale: Locale = .current) -> String {
        guard !picks.isEmpty else { return "" }
        let parts = picks.map { label($0, zone: zone, now: now, locale: locale) }
        let joined: String
        if parts.count == 1 { joined = parts[0] }
        else { joined = parts.dropLast().joined(separator: ", ") + " or " + parts[parts.count - 1] }
        var out = joined + " " + (zone.abbreviation(for: picks[0].start) ?? zone.identifier)
        if let link, !link.isEmpty { out += " — or pick one: " + link }
        return out
    }

    /// "Tue 2–2:30pm". The day carries its number once it is more than six
    /// days out, because "Tue" alone then means two different days.
    public static func label(_ s: Slot, zone: TimeZone, now: Date, locale: Locale) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = zone
        let farOut = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: s.start).day ?? 0
        day.setLocalizedDateFormatFromTemplate(farOut > 6 ? "EEE d" : "EEE")
        return day.string(from: s.start) + " " + span(s, zone: zone, locale: locale)
    }

    /// "2–2:30pm", "11:30am–12pm", or "14:00–14:30" where the locale counts
    /// to 24. The period is said once when both ends share it.
    public static func span(_ s: Slot, zone: TimeZone, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("j")
        let twelveHour = f.dateFormat.contains("a")
        if !twelveHour {
            f.dateFormat = "HH:mm"
            return f.string(from: s.start) + "–" + f.string(from: s.end)
        }
        f.dateFormat = "a"
        let startPeriod = f.string(from: s.start).lowercased()
        let endPeriod = f.string(from: s.end).lowercased()
        let start = clock(s.start, zone: zone, locale: locale)
        let end = clock(s.end, zone: zone, locale: locale)
        if startPeriod == endPeriod { return "\(start)–\(end)\(endPeriod)" }
        return "\(start)\(startPeriod)–\(end)\(endPeriod)"
    }

    /// "2", "2:30" — the minutes only when they are not zero.
    private static func clock(_ d: Date, zone: TimeZone, locale: Locale) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.hour, .minute], from: d)
        let h12 = (c.hour ?? 0) % 12 == 0 ? 12 : (c.hour ?? 0) % 12
        return (c.minute ?? 0) == 0 ? "\(h12)" : String(format: "%d:%02d", h12, c.minute ?? 0)
    }
}
