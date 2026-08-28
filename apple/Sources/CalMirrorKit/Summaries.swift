import Foundation

/// One-line descriptions of a mirror's settings, for UI rows that stay collapsed
/// until you need them: the list row's second line, and the summary under each
/// section header in the editor.
///
/// These live in the kit rather than in the SwiftUI layer so the menu-bar app,
/// the App Store Mac app and the iOS app all render the same words for the same
/// config — and so they're checkable from `cmk-check`.
public enum MirrorSummary {

    // MARK: Projection

    /// What crosses over, e.g. "Busy only" or "Title redacted · tags only".
    public static func projection(_ p: Projection) -> String {
        if !p.custom {
            switch preset(of: p) {
            case .details: return "Title and location"
            case .full: return "Full copy"
            case .busy: return "Busy only"
            case .custom: break
            }
        }
        var parts: [String] = []
        parts.append(p.title == .redact ? "Shown as “\(p.titleText)”" : "Real title")
        if !p.location { parts.append("no location") }
        switch p.notes {
        case .none: break
        case .tags: parts.append("tags only")
        case .full: parts.append("full notes")
        }
        if p.alarms { parts.append("alarms") }
        if p.availability == .busy { parts.append("always busy") }
        return parts.joined(separator: " · ")
    }

    /// The named presets the editor offers; `custom` is "none of the above".
    public enum Preset: Sendable { case details, full, busy, custom }

    public static func preset(of p: Projection) -> Preset {
        let redact = p.title == .redact, busy = p.availability == .busy
        if !redact && p.location && p.notes == .none && !p.alarms && !busy { return .details }
        if !redact && p.location && p.notes == .full && !p.alarms && !busy { return .full }
        if redact && !p.location && p.notes == .none && !p.alarms && busy { return .busy }
        return .custom
    }

    // MARK: Selection

    /// Which events are copied, e.g. "Skips declined, all-day · 8am–6pm · only #ref",
    /// or "Every event" when nothing is filtered.
    public static func selection(_ f: EventFilters, tagFilter: TagFilter?) -> String {
        var chunks: [String] = []

        var skips: [String] = []
        if f.declined { skips.append("declined") }
        if f.unanswered { skips.append("unanswered") }
        if f.canceled { skips.append("canceled") }
        if f.allDay { skips.append("all-day") }
        if f.free { skips.append("free") }
        if f.shorterThanMinutes > 0 { skips.append("under \(f.shorterThanMinutes)m") }
        if f.longerThanMinutes > 0 { skips.append("over \(f.longerThanMinutes)m") }
        if !skips.isEmpty { chunks.append("Skips " + skips.joined(separator: ", ")) }

        if let t = f.title, t.isActive {
            let list = t.patterns.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: ", ")
            chunks.append(t.mode == .include ? "title has \(list)" : "not \(list)")
        }

        if let h = f.hours, h.isActive {
            let span = "\(clock(h.startMinute))–\(clock(h.endMinute))"
            let when = h.days.isEmpty ? span : "\(span) \(dayList(h.days))"
            chunks.append(h.mode == .keep ? when : "outside \(when)")
        }

        if let tf = tagFilter, tf.isActive {
            let list = tf.tags.joined(separator: " ")
            chunks.append(tf.mode == .include ? "only \(list)" : "not \(list)")
        }

        return chunks.isEmpty ? "Every event" : chunks.joined(separator: " · ")
    }

    /// The list row's second line: what makes THIS mirror different from a plain
    /// copy-everything mirror. nil when nothing does, so an ordinary mirror shows
    /// no extra line and the unusual ones stand out in a long list.
    ///
    /// Deliberately terser than `projection` + `selection`: this sits on one line
    /// in a list, so it names only what diverges from the defaults and counts the
    /// filters rather than spelling them out. The editor's summary rows are where
    /// the full wording belongs.
    public static func delta(_ m: Mirror) -> String? {
        var parts: [String] = []

        switch preset(of: m.projection) {
        case .details: break                       // the default — not a delta
        case .full: parts.append("Full copy")
        case .busy: parts.append("Busy only")
        case .custom:
            var bits: [String] = []
            if m.projection.title == .redact { bits.append("redacted") }
            if !m.projection.location { bits.append("no location") }
            if m.projection.notes == .tags { bits.append("tags only") }
            if m.projection.notes == .full { bits.append("full notes") }
            if m.projection.availability == .busy { bits.append("always busy") }
            parts.append(bits.isEmpty ? "Custom" : bits.joined(separator: ", "))
        }

        var rules = m.filters.activeRuleCount
        if m.tagFilter?.isActive == true { rules += 1 }
        if rules > 0 { parts.append(rules == 1 ? "1 rule" : "\(rules) rules") }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Advanced section's summary, e.g. "Window 30 / 365 · heartbeat on".
    public static func advanced(_ m: Mirror) -> String {
        let hb = m.showHeartbeat ? "heartbeat on" : "heartbeat off"
        return "Window \(Int(m.windowPastDays)) / \(Int(m.windowFutureDays)) · \(hb)"
    }

    // MARK: Bits

    /// Minutes-from-midnight as a compact 12-hour clock: 480 → "8am", 1050 → "5:30pm".
    /// Deliberately terse — these strings sit in a one-line summary, not a field.
    public static func clock(_ minutes: Int) -> String {
        let m = ((minutes % (24 * 60)) + 24 * 60) % (24 * 60)
        let h24 = m / 60, min = m % 60
        let suffix = h24 < 12 ? "am" : "pm"
        var h12 = h24 % 12; if h12 == 0 { h12 = 12 }
        return min == 0 ? "\(h12)\(suffix)" : String(format: "%d:%02d%@", h12, min, suffix)
    }

    /// Weekday numbers (1 = Sunday) as "Mon–Fri", "Sat, Sun", etc. Collapses a
    /// contiguous run into a range; anything else is listed.
    public static func dayList(_ days: [Int]) -> String {
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let sorted = Array(Set(days.filter { (1...7).contains($0) })).sorted()
        guard !sorted.isEmpty else { return "" }
        if sorted.count == 7 { return "every day" }
        let contiguous = zip(sorted, sorted.dropFirst()).allSatisfy { $1 == $0 + 1 }
        if contiguous && sorted.count > 2 { return "\(names[sorted.first!])–\(names[sorted.last!])" }
        return sorted.map { names[$0] }.joined(separator: ", ")
    }
}
