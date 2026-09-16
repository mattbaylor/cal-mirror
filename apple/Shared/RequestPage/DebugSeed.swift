#if DEBUG
import Foundation
import EventKit
import CalMirrorKit

/// Screenshot scaffolding. **Three gates, and all three must hold:**
///
/// 1. `#if DEBUG` — the whole file does not exist in a Release build, so
///    nothing here can ship.
/// 2. `#if targetEnvironment(simulator)` on everything that writes — a debug
///    build on a real device cannot touch a real calendar even if somebody
///    passes the argument by hand.
/// 3. An explicit launch argument — a debug build in a simulator that nobody
///    asked to seed does nothing either.
///
/// The belt and braces are deliberate. This writes calendar events and a
/// config file, which are exactly the two things that would be expensive to do
/// to somebody's real machine by accident, and a single `#if DEBUG` is one
/// careless scheme edit away from being on.
enum DebugSeed {

    /// `-AskWhenSeed` — write the synthetic calendar and config.
    static let seedArgument = "-AskWhenSeed"
    /// `-AskWhenScreen <name>` — open straight at one screen, so screenshots
    /// need no UI automation to navigate. `RequestPageSetupView` already takes
    /// a starting step; this is only a way to say which from outside.
    static let screenArgument = "-AskWhenScreen"
    /// The calendar this creates and owns. Named so that a human finding it in
    /// a simulator knows immediately what it is and that deleting it is safe.
    static let calendarTitle = "AskWhen Screenshots"

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static var isRequested: Bool {
        isSimulator && ProcessInfo.processInfo.arguments.contains(seedArgument)
    }

    /// Which screen to open at, if one was named.
    static var startStep: RequestPageSetupView.Step? {
        guard isSimulator else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: screenArgument), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "explainer": return .explainer
        case "calendars": return .calendars
        case "display":   return .display
        case "policy":    return .policy
        case "preview":   return .preview
        case "offer":     return .offer
        case "live":      return .live
        default:          return nil
        }
    }

    /// `-AskWhenConflict` — present the conflict sheet over whatever is on
    /// screen, built from the same synthetic requester the review uses.
    static var wantsConflict: Bool {
        isSimulator && ProcessInfo.processInfo.arguments.contains("-AskWhenConflict")
    }

    /// `-AskWhenRequest` — one request in the queue and its notification on
    /// screen, so Accept and Decline can be exercised by hand. No test does,
    /// and nothing short of a live page otherwise can. The request lands on
    /// top of a seeded event on purpose: the interesting path is the one where
    /// Accept re-checks the calendar and finds the time taken.
    static var wantsRequest: Bool {
        isSimulator && ProcessInfo.processInfo.arguments.contains("-AskWhenRequest")
    }

    /// A request for the seeded "League ops sync" hour. A slot inside it is a
    /// conflict for the checker; the request is the same synthetic one the
    /// conflict sheet uses so the two frames agree.
    static func sampleRequest(_ zone: TimeZone) -> IncomingRequest {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let tomorrow = cal.startOfDay(for: Date()).addingTimeInterval(86400)
        let slot = Slot(start: tomorrow.addingTimeInterval(10 * 3600),
                        end: tomorrow.addingTimeInterval(10.5 * 3600))
        return IncomingRequest(id: "seed-request-1", slot: slot,
                               name: "Priya Raman", email: "priya@example.org",
                               note: "Wanted to ask about the referee assignment tool before the season starts.",
                               holdUntil: Date().addingTimeInterval(86400))
    }

    /// Puts the request where a poll would have put it and posts what a poll
    /// would have posted. The token is invented too — `accept` refuses to run
    /// without one, and the re-check is local; only the resolve afterwards
    /// reaches the service, which will refuse the token, and that refusal is
    /// itself a state worth seeing.
    ///
    /// This is the one seed that turns the page on. A request cannot exist
    /// without a page, and the argument is an explicit ask for one — the rule
    /// that seeding never skips the opt-in is about the setup flow, which this
    /// is not photographing. The slug is the glossary's example and answers
    /// 404 on the service, which the coordinator reads as "already resolved".
    @MainActor
    static func seedRequest(into store: Store) {
        guard wantsRequest else { return }
        if store.requestPage.slug.isEmpty {
            store.requestPage.slug = "x7f2k9"
            store.requestPage.enabled = true
            store.save()
        }
        try? KeychainTokenStore().store("seed-token", for: store.requestPage.slug)
        let request = sampleRequest(store.zone)
        if !store.pendingRequests.contains(where: { $0.id == request.id }) {
            store.pendingRequests.append(request)
        }
        RequestNotifications.registerCategory()
        RequestNotifications.post(request, zone: store.zone)
    }

    /// A conflict to photograph. Built rather than provoked: making a real one
    /// needs a request in the queue and an event landing on it, which is a lot
    /// of live state to arrange for a picture of a sheet.
    static func sampleConflict(_ zone: TimeZone) -> RequestConflict {
        // Anchored on the start of the day, not on now: "three days from now
        // plus 13.5 hours" is 1:30 PM only when run at midnight, and a review
        // frame that says a stranger asked for 3:55 AM reads as a bug in the
        // sheet rather than in the seed.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let day = cal.startOfDay(for: Date()).addingTimeInterval(3 * 86400)
        let slot = Slot(start: day.addingTimeInterval(13.5 * 3600),
                        end: day.addingTimeInterval(14 * 3600))
        return RequestConflict(
            request: IncomingRequest(id: "seed-1", slot: slot,
                                     name: "Priya Raman", email: "priya@example.org",
                                     note: "Wanted to ask about the referee assignment tool before the season starts.",
                                     holdUntil: Date().addingTimeInterval(86400)),
            alternatives: [
                Slot(start: slot.start.addingTimeInterval(5400), end: slot.end.addingTimeInterval(5400)),
                Slot(start: slot.start.addingTimeInterval(86400), end: slot.end.addingTimeInterval(86400)),
            ],
            landed: [BusyInterval(start: slot.start.addingTimeInterval(-1800),
                                  end: slot.end.addingTimeInterval(1800))],
            zone: zone)
    }

    // MARK: Seeding

    /// Writes a week of plausible events into its own calendar and points the
    /// page's blocking list at it. Without this the preview is honestly empty —
    /// a fresh simulator has no events, so the deriver has nothing to work
    /// around and every screenshot of screen 6 would show a page with nothing
    /// on it.
    @MainActor
    static func apply(to store: Store) async {
        guard isRequested else { return }
        let events = EKEventStore()
        guard (try? await events.requestFullAccessToEvents()) == true else { return }
        guard let calendar = calendar(in: events) else { return }
        seedEvents(in: calendar, using: events)

        store.calendars = store.engine.calendars()
        // The same CalRef the calendars screen builds — title *and* account —
        // or the row's toggle compares unequal and shows the seeded calendar
        // as not blocking while the deriver treats it as blocking.
        let info = store.calendars.first { $0.title == calendarTitle }
        let ref = CalRef(title: calendarTitle, account: info?.account)
        var page = store.requestPage
        page.blocking = [ref]
        page.requestCalendar = ref
        // Still not enabled and still no slug: the opt-in is the thing worth
        // seeing from the start, and a seeded live page would hide it.
        store.requestPage = page
        store.save()
        seedRequest(into: store)
    }

    private static func calendar(in events: EKEventStore) -> EKCalendar? {
        if let existing = events.calendars(for: .event).first(where: { $0.title == calendarTitle }) {
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: events)
        cal.title = calendarTitle
        cal.source = events.sources.first { $0.sourceType == .local }
            ?? events.defaultCalendarForNewEvents?.source
        guard cal.source != nil, (try? events.saveCalendar(cal, commit: true)) != nil else { return nil }
        return cal
    }

    /// A week that produces an interesting preview rather than an empty or a
    /// full one: some days busy, one day covered, one day left open. The point
    /// of screen 6 is that the accounting adds up, and it cannot demonstrate
    /// that against an empty calendar.
    private static func seedEvents(in calendar: EKCalendar, using events: EKEventStore) {
        // Clear whatever a previous run left, so screenshots are reproducible
        // rather than accumulating.
        let horizon = Date().addingTimeInterval(30 * 86400)
        let predicate = events.predicateForEvents(withStart: Date().addingTimeInterval(-86400),
                                                  end: horizon, calendars: [calendar])
        for event in events.events(matching: predicate) {
            try? events.remove(event, span: .thisEvent, commit: false)
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Denver") ?? .current
        let today = cal.startOfDay(for: Date())

        // (day offset, start hour, minutes, title). Titles are invented and
        // never leave the device — they exist so a screenshot of the simulator's
        // own Calendar app does not look like placeholder noise.
        let plan: [(Int, Int, Int, String)] = [
            (1, 10, 60, "League ops sync"), (1, 14, 30, "Referee check-in"),
            (2, 9, 90, "Assignment review"),
            (3, 9, 480, "Tournament — all day on site"),
            (4, 11, 60, "Budget"), (4, 15, 60, "Coach call"),
            (7, 13, 60, "Board"),
        ]
        for (day, hour, minutes, title) in plan {
            guard let start = cal.date(byAdding: .hour, value: hour,
                                       to: cal.date(byAdding: .day, value: day, to: today) ?? today)
            else { continue }
            let event = EKEvent(eventStore: events)
            event.calendar = calendar
            event.title = title
            event.startDate = start
            event.endDate = start.addingTimeInterval(TimeInterval(minutes) * 60)
            try? events.save(event, span: .thisEvent, commit: false)
        }
        try? events.commit()
    }
}
#endif
