#if DEBUG
import EventKit
import Foundation
import CalMirrorKit

/// `-EngineCheck`: the EventKit layer, run for real.
///
/// `cmk-check` covers everything that can be made pure, and that stops at
/// `MirrorEngine`, which is the code that actually reads and writes calendars
/// and where the bugs that reach a user's calendar live. This drives the real
/// engine against real EventKit, in the simulator, on calendars it makes for
/// the purpose and deletes afterwards, and exits 0 or 1. CI runs it on every
/// change to the engine (`.github/workflows/engine-check.yml`); locally:
///
///     apple/tools/engine-check.sh
///
/// Simulator and debug only, like `DebugSeed`: it creates and deletes
/// calendars, which is not something a build on a phone should ever be able
/// to be asked to do.
enum EngineCheck {
    static let argument = "-EngineCheck"
    /// Every calendar this makes starts with it, so a run that died halfway
    /// is cleaned up by the next.
    static let prefix = "EngineCheck "

    static var isRequested: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains(argument)
        #else
        false
        #endif
    }

    /// Runs on its own thread, because the engine sleeps while it waits for a
    /// destination to settle, and exits the app with the verdict.
    static func start() {
        Thread.detachNewThread {
            let failures = Runner().run()
            exit(failures == 0 ? 0 : 1)
        }
    }
}

private final class Runner {
    let store = EKEventStore()
    var failures = 0
    let now = Date()

    func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    func check(_ ok: Bool, _ what: String) {
        say("  \(ok ? "✓" : "✗ FAIL") \(what)")
        if !ok { failures += 1 }
    }

    // MARK: Fixtures

    func calendar(_ name: String) -> EKCalendar? {
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = EngineCheck.prefix + name
        cal.source = store.sources.first { $0.sourceType == .local }
            ?? store.defaultCalendarForNewEvents?.source
        do { try store.saveCalendar(cal, commit: true); return cal }
        catch { say("  ✗ FAIL could not create \(cal.title): \(error.localizedDescription)"); failures += 1; return nil }
    }

    func info(_ c: EKCalendar) -> CalendarInfo {
        CalendarInfo(title: c.title, account: c.source.title, identifier: c.calendarIdentifier,
                     writable: c.allowsContentModifications)
    }

    /// Tomorrow at `hour`, plus `days`. Clear of the window's edges and of now.
    func at(days: Int, hour: Int) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: 1 + days, to: Calendar.current.startOfDay(for: now))!
        return Calendar.current.date(byAdding: .hour, value: hour, to: day)!
    }

    @discardableResult
    func event(_ title: String, in cal: EKCalendar, days: Int, hour: Int = 10, minutes: Int = 60,
               allDay: Bool = false, location: String? = nil, notes: String? = nil,
               availability: EKEventAvailability = .busy, weeklyCount: Int? = nil) -> EKEvent {
        let ev = EKEvent(eventStore: store)
        ev.calendar = cal
        ev.title = title
        ev.startDate = at(days: days, hour: hour)
        ev.endDate = ev.startDate.addingTimeInterval(TimeInterval(minutes * 60))
        ev.isAllDay = allDay
        ev.location = location
        ev.notes = notes
        ev.availability = availability
        if let n = weeklyCount {
            ev.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                                  end: EKRecurrenceEnd(occurrenceCount: n)))
        }
        do { try store.save(ev, span: .futureEvents, commit: true) }
        catch { say("  ✗ FAIL could not save \(title): \(error.localizedDescription)"); failures += 1 }
        return ev
    }

    func events(in cal: EKCalendar) -> [EKEvent] {
        store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-2 * 86400),
                                                        end: now.addingTimeInterval(60 * 86400),
                                                        calendars: [cal]))
    }

    func copies(in cal: EKCalendar) -> [EKEvent] {
        events(in: cal).filter { ($0.url?.scheme ?? "") == Markers.scheme }
    }

    func banners(in cal: EKCalendar) -> [EKEvent] {
        events(in: cal).filter { ($0.url?.scheme ?? "") == Markers.heartbeatScheme }
    }

    func cleanUp() {
        for c in store.calendars(for: .event) where c.title.hasPrefix(EngineCheck.prefix) {
            try? store.removeCalendar(c, commit: true)
        }
    }

    /// The engine's own progress lines, indented under the checks, so a
    /// failure arrives with what the engine said it did.
    func sync(_ engine: MirrorEngine, _ mirrors: Mirror...) -> MirrorResult {
        var c = Config()
        c.mirrors = mirrors
        return engine.syncAll(c, log: { self.say("      engine: \($0)") })[0]
    }

    func config(_ mirrors: Mirror...) -> Config {
        var c = Config()
        c.mirrors = mirrors
        return c
    }

    // MARK: The run

    func run() -> Int {
        say("Engine check (EventKit, simulator):")
        let engine = MirrorEngine(store: store)
        let access = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var granted = false
        Task.detached { granted = await engine.requestAccess(); access.signal() }
        access.wait()
        guard granted else {
            say("  ✗ FAIL no full calendar access — run apple/tools/grant-calendar.sh before launching")
            return 1
        }
        cleanUp()
        defer { cleanUp() }

        guard let source = calendar("Source"), let dest = calendar("Dest"),
              let busyDest = calendar("Busy"), let twin1 = calendar("Twin"), let twin2 = calendar("Twin"),
              let lonely = calendar("Lonely") else { return failures + 1 }

        // Copy
        say("Copy:")
        event("Standup", in: source, days: 0, location: "Room 1")
        event("Offsite", in: source, days: 1, allDay: true)
        event("Private thing", in: source, days: 2, notes: "#nomirror")
        event("Weekly", in: source, days: 3, hour: 14, weeklyCount: 4)
        let m = Mirror(id: "ec1", name: "Check", source: CalRef(info(source)), dest: CalRef(info(dest)))
        var r = sync(engine, m)
        check(r.ok, "a first sync succeeds (\(r.error ?? "no error"))")
        let first = copies(in: dest)
        check(first.count == 6 && r.created == 6,
              "a plain, an all-day and four weekly occurrences are copied (\(first.count) copies, \(r.created) created)")
        check(!first.contains { $0.title == "Private thing" }, "#nomirror is not copied")
        check(first.first { $0.title == "Offsite" }?.isAllDay == true, "all-day stays all-day")
        check(first.first { $0.title == "Standup" }?.location == "Room 1", "location crosses in a full copy")

        r = sync(engine, m)
        check(r.ok && r.created == 0 && r.updated == 0 && r.deleted == 0 && copies(in: dest).count == 6,
              "a second sync changes nothing (+\(r.created) ~\(r.updated) -\(r.deleted))")

        // Edit and delete
        say("Edits follow the source:")
        let standup = events(in: source).first { $0.title == "Standup" }!
        standup.title = "Standup (moved)"
        try? store.save(standup, span: .thisEvent, commit: true)
        r = sync(engine, m)
        let titles = Set(copies(in: dest).compactMap(\.title))
        check(r.updated == 1 && titles.contains("Standup (moved)") && !titles.contains("Standup"),
              "a renamed event is updated in place (~\(r.updated))")
        let offsite = events(in: source).first { $0.title == "Offsite" }!
        try? store.remove(offsite, span: .thisEvent, commit: true)
        r = sync(engine, m)
        check(r.deleted == 1 && copies(in: dest).count == 5, "a deleted event's copy is removed (-\(r.deleted))")

        // Projection
        say("Busy blocks:")
        let busy = Mirror(id: "ec2", name: "Busy check", source: CalRef(info(source)), dest: CalRef(info(busyDest)),
                          projection: Projection(title: .redact, titleText: "Busy", location: false))
        r = sync(engine, busy)
        let blocks = copies(in: busyDest)
        check(r.ok && blocks.count == 5 && blocks.allSatisfy { $0.title == "Busy" },
              "every copy is titled Busy (\(blocks.count) copies)")
        check(blocks.allSatisfy { ($0.location ?? "").isEmpty }, "and carries no location")

        // Calendar references (#182)
        say("Calendars are found by identifier:")
        let oldTitle = dest.title
        dest.title = EngineCheck.prefix + "Dest renamed"
        try? store.saveCalendar(dest, commit: true)
        r = sync(engine, m)
        check(r.ok && copies(in: dest).count == 5, "a renamed destination keeps its mirror (\(r.error ?? "ok"))")
        let byName = Mirror(id: "ec3", name: "By name", source: CalRef(info(source)), dest: CalRef(title: oldTitle))
        r = sync(engine, byName)
        check(!r.ok && r.error == "Destination not found", "a reference by the old title alone does not find it")

        let toTwin = Mirror(id: "ec4", name: "Twin", source: CalRef(info(source)), dest: CalRef(info(twin2)))
        r = sync(engine, toTwin)
        check(r.ok && copies(in: twin2).count == 5 && copies(in: twin1).isEmpty,
              "of two calendars with the same title, the one picked gets the copies")

        // Warning banner
        say("The warning in the calendar:")
        let broken = Mirror(id: "ec5", name: "Broken", source: CalRef(title: EngineCheck.prefix + "Missing"),
                            dest: CalRef(info(lonely)))
        r = sync(engine, broken)
        check(!r.ok && r.error == "Source not found", "a missing source fails the mirror")
        check(banners(in: lonely).count == 1, "and raises one warning in the destination")
        r = sync(engine, broken)
        check(banners(in: lonely).count == 1, "a second failing cycle does not add another")
        var fixed = broken; fixed.source = CalRef(info(source))
        r = sync(engine, fixed)
        check(r.ok && banners(in: lonely).isEmpty, "the first clean cycle clears it (\(r.error ?? "ok"))")

        // Accepted requests
        say("Accepted requests:")
        do {
            let a = try engine.writeAcceptedEvent(requestID: "ec-req-1", title: "Chat", location: nil, notes: "n",
                                                  start: at(days: 5, hour: 9), end: at(days: 5, hour: 10),
                                                  into: CalRef(info(lonely)))
            let b = try engine.writeAcceptedEvent(requestID: "ec-req-1", title: "Chat", location: nil, notes: "n",
                                                  start: at(days: 5, hour: 9), end: at(days: 5, hour: 10),
                                                  into: CalRef(info(lonely)))
            let written = events(in: lonely).filter { $0.url?.absoluteString == "\(MirrorEngine.requestScheme):ec-req-1" }
            check(a == b && written.count == 1, "accepting the same request twice writes one event")
        } catch {
            check(false, "writing an accepted request threw \(error.localizedDescription)")
        }

        // Busy intervals
        say("What blocks a request page:")
        event("Real meeting", in: source, days: 6, hour: 11)
        if source.supportedEventAvailabilities.contains(.free) {
            event("Free time", in: source, days: 6, hour: 9, availability: .free)
            let intervals = engine.busyIntervals(in: [CalRef(info(source))], from: at(days: 6, hour: 0), to: at(days: 7, hour: 0))
            check(intervals.count == 1 && intervals.first?.start == at(days: 6, hour: 11),
                  "a busy event blocks and a free one does not (\(intervals.count) intervals)")
        } else {
            let intervals = engine.busyIntervals(in: [CalRef(info(source))], from: at(days: 6, hour: 0), to: at(days: 7, hour: 0))
            check(intervals.count == 1 && intervals.first?.start == at(days: 6, hour: 11),
                  "a busy event blocks (\(intervals.count) intervals)")
            say("  - skipped: a free event does not block (a local calendar cannot mark one free)")
        }

        // Purge
        say("Purge:")
        event("Hand made", in: dest, days: 4)
        let (removed, purgeFailures) = engine.purge(config(m, busy, toTwin, fixed))
        check(purgeFailures.isEmpty, "purge reports no failures \(purgeFailures)")
        check(removed == 20, "and removes every copy the four mirrors made (\(removed))")
        check(copies(in: dest).isEmpty && copies(in: busyDest).isEmpty && copies(in: twin2).isEmpty,
              "leaving no copies behind")
        check(events(in: dest).contains { $0.title == "Hand made" }, "and an event the owner made untouched")

        say(failures == 0 ? "\nALL ENGINE CHECKS PASSED" : "\n\(failures) ENGINE CHECK(S) FAILED")
        return failures
    }
}
#endif
