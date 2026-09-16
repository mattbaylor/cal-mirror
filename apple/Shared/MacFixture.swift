#if DEBUG
import Foundation
import CalMirrorKit

/// A synthetic Mac, for captures. Launch with `-CalMirrorFixture` and the
/// store app never asks EventKit for anything: the calendars, the mirrors and
/// their statuses all come from here, and nothing is saved.
///
/// This exists because of the rule in `appstore/README.md` — no real calendar
/// data appears in any capture — and because the store app, unlike the
/// standalone one, reads its calendar list from EventKit. On the machine that
/// takes the screenshots that list is Matt's; a picker on screen would show
/// it. Not asking is the only version of "never" that survives someone
/// forgetting. The names are the README's invented set, and `save()` is a
/// no-op under this flag so the real container's config is never overwritten
/// by a screenshot session.
///
/// Debug-only and macOS-only: `#if DEBUG` on the file, and the argument is
/// read nowhere else, so a release build has no path that skips EventKit.
enum MacFixture {
    static let argument = "-CalMirrorFixture"

    static var isRequested: Bool {
        #if os(macOS)
        return ProcessInfo.processInfo.arguments.contains(argument)
        #else
        return false
        #endif
    }

    /// `-CalMirrorFixtureExpand projection|selection|advanced` — open the
    /// window with that group expanded, for the capture of it.
    static var expand: String? { value(after: "-CalMirrorFixtureExpand") }

    /// `-CalMirrorFixtureSize 940x880` — the window's content size, so each
    /// capture matches the size the store composites crop to.
    static var size: (width: Double, height: Double)? {
        guard let v = value(after: "-CalMirrorFixtureSize") else { return nil }
        let parts = v.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// `-CalMirrorFixtureWarning` — the first mirror reports a failure, for
    /// the capture that shows what a broken mirror looks like.
    static var wantsWarning: Bool {
        isRequested && ProcessInfo.processInfo.arguments.contains("-CalMirrorFixtureWarning")
    }

    private static func value(after flag: String) -> String? {
        guard isRequested else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static let calendars: [CalendarInfo] = [
        CalendarInfo(title: "Work", account: "Exchange", identifier: "fx-work", writable: true),
        CalendarInfo(title: "Team On-Call", account: "Exchange", identifier: "fx-oncall", writable: true),
        CalendarInfo(title: "Personal", account: "iCloud", identifier: "fx-personal", writable: true),
        CalendarInfo(title: "Work (Copy)", account: "iCloud", identifier: "fx-copy", writable: true),
        CalendarInfo(title: "Shared Availability", account: "iCloud", identifier: "fx-shared", writable: true),
        CalendarInfo(title: "US Holidays", account: "Subscribed", identifier: "fx-holidays", writable: false),
    ]

    static var config: Config {
        var c = Config.empty
        var work = Mirror(id: "fx-m1", name: "Work → Personal",
                          source: CalRef(title: "Work", account: "Exchange"),
                          dest: CalRef(title: "Work (Copy)", account: "iCloud"))
        work.projection.titlePrefix = "[Work]"
        work.projection.sourceLink = true
        work.filters = EventFilters(declined: true, canceled: true, allDay: true, free: true,
                                    shorterThanMinutes: 15,
                                    title: .init(mode: .reject, patterns: ["Lunch", "Focus time"]),
                                    hours: .init(mode: .keep, startMinute: 8 * 60, endMinute: 18 * 60,
                                                 days: [2, 3, 4, 5, 6]))
        work.showHeartbeat = true

        var oncall = Mirror(id: "fx-m2", name: "On-Call → Personal",
                            source: CalRef(title: "Team On-Call", account: "Exchange"),
                            dest: CalRef(title: "Work (Copy)", account: "iCloud"))
        oncall.projection.titlePrefix = "[On-Call]"
        oncall.projection.title = .redact
        oncall.projection.location = false

        var busy = Mirror(id: "fx-m3", name: "Availability → Shared",
                          source: CalRef(title: "Personal", account: "iCloud"),
                          dest: CalRef(title: "Shared Availability", account: "iCloud"))
        busy.projection.title = .redact
        busy.projection.location = false
        busy.projection.availability = .busy
        busy.filters = EventFilters(allDay: true)

        c.mirrors = [work, oncall, busy]
        return c
    }

    static var statuses: [String: MirrorResult] { [
        "fx-m1": wantsWarning
            ? MirrorResult(id: "fx-m1", name: "Work → Personal", ok: false,
                           error: "Destination calendar “Work (Copy)” is read-only — the account no longer allows writes.")
            : MirrorResult(id: "fx-m1", name: "Work → Personal", ok: true, created: 3, updated: 1, unchanged: 435),
        "fx-m2": MirrorResult(id: "fx-m2", name: "On-Call → Personal", ok: true, unchanged: 86),
        "fx-m3": MirrorResult(id: "fx-m3", name: "Availability → Shared", ok: true, updated: 2, unchanged: 22),
    ] }
}
#endif
