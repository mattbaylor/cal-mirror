import Foundation

/// Decides what the in-calendar status banner should do after a sync.
///
/// The banner used to write on every *successful* cycle — a daily all-day event
/// carrying an event count and a clock time. That was the wrong shape twice
/// over. The count was decoration (nobody notices 612 becoming 613), and the
/// destinations are calendars you deliberately SHARE, so a daily marker is an
/// artifact other people see. Paying that every day to say "still working" is a
/// bad trade.
///
/// So it is inverted: **healthy is silent**. A banner appears only when a mirror
/// stops syncing, which makes its presence the signal and makes it actionable
/// rather than reassuring. It is also loop-free by construction — writes are
/// rare and exceptional, which matters because every write to a destination
/// posts an EventKit change notification.
///
/// Pure, so `cmk-check` covers it without EventKit — the same shape as
/// `Reconciler`, `ReverseDetector` and `SnapshotGuard`.
public enum HeartbeatPolicy {

    /// What this cycle learned about one mirror.
    public enum Health: Equatable, Sendable {
        case ok
        case failing(String)   // the error to surface, e.g. "Source not found"
        /// Nothing was learned — the cycle deferred (an unsettled destination
        /// snapshot), or the mirror is paused or disabled. Deliberately distinct
        /// from `ok`: a deferral is not evidence of health, so it must neither
        /// raise a warning nor clear one that is already up.
        case unknown
    }

    public enum Action: Equatable, Sendable {
        case none                  // leave the destination exactly as it is
        case remove                // clear an existing banner
        case write(title: String)  // create or update the banner
    }

    /// - Parameters:
    ///   - enabled: the mirror's `showHeartbeat` — "warn me in the calendar".
    ///   - health: what this cycle established.
    ///   - existingTitle: the current banner's title, or nil if there is none.
    ///   - lastSuccess: when this mirror last synced cleanly, if known.
    public static func decide(enabled: Bool,
                              health: Health,
                              existingTitle: String?,
                              mirrorName: String,
                              lastSuccess: Date?,
                              now: Date,
                              calendar: Calendar = .current) -> Action {
        // Turned off: clear anything we left behind. This is also what migrates
        // the old always-on banners away on the first upgrade cycle.
        guard enabled else { return existingTitle == nil ? .none : .remove }

        switch health {
        case .unknown:
            return .none
        case .ok:
            return existingTitle == nil ? .none : .remove
        case .failing(let reason):
            let desired = title(mirrorName: mirrorName, reason: reason,
                                lastSuccess: lastSuccess, now: now, calendar: calendar)
            // Only write when the text actually differs. A mirror that has been
            // broken for a week must not re-save an identical banner every cycle
            // — that is exactly the self-triggering write the inversion exists to
            // remove.
            return existingTitle == desired ? .none : .write(title: desired)
        }
    }

    /// The banner text. Names the mirror and what went wrong, and dates the last
    /// clean sync when we know it — "hasn't synced since Tue 26 Aug" is the part
    /// that tells you how alarmed to be.
    public static func title(mirrorName: String, reason: String,
                             lastSuccess: Date?, now: Date,
                             calendar: Calendar = .current) -> String {
        var s = "⚠︎ Calendar Mirror — \(mirrorName): \(reason)"
        if let lastSuccess, !calendar.isDate(lastSuccess, inSameDayAs: now) {
            s += " · last synced \(dayLabel(lastSuccess, calendar: calendar))"
        }
        return s
    }

    /// "Tue 26 Aug". Built from date components rather than a DateFormatter so
    /// it is identical whatever locale the machine runs in — this string is a
    /// diagnostic, and a test that passes only in en_US is not a test.
    public static func dayLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let days = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let c = calendar.dateComponents([.weekday, .day, .month], from: date)
        let wd = days[min(max(c.weekday ?? 1, 1), 7)]
        let mo = months[min(max(c.month ?? 1, 1), 12)]
        return "\(wd) \(c.day ?? 1) \(mo)"
    }
}
