// cal-mirror — one-way mirror of any Mac calendar into any other Mac calendar.
//
// This is a THIN entry point. All sync logic lives in CalMirrorKit (the same
// engine the App Store apps use); build.sh compiles this file together with
// apple/Sources/CalMirrorKit/*.swift into one module, so there is a single
// implementation to maintain — no parallel reimplementation.
//
// The process is a long-lived daemon (launchd KeepAlive): it keeps ONE
// MirrorEngine — and thus one warm EKEventStore plus the engine's per-mirror
// owned-count baseline (SnapshotGuard) — alive across sync cycles, then sleeps
// the configured interval. That warm, stable view is what prevents acting on a
// cold/partial CalDAV snapshot (the source of duplicate/delete churn).
//
// Runtime settings come from config.json (written by the menu-bar UI); each
// cycle emits status.json for the UI and calendars.json for its pickers.
//
// Usage:  cal-mirror                 run as a daemon (default; launchd loads this)
//         cal-mirror --once          run a single sync cycle, then exit
//         cal-mirror --list-calendars print every Mac calendar as JSON, then exit
//         cal-mirror --purge         remove ALL mirror-tagged events, then exit

import EventKit
import Foundation

// ---- Paths ---------------------------------------------------------------
let SUPPORT_DIR = ("~/.local/cal-mirror" as NSString).expandingTildeInPath
let CONFIG_URL = URL(fileURLWithPath: SUPPORT_DIR + "/config.json")
let STATUS_URL = URL(fileURLWithPath: SUPPORT_DIR + "/status.json")
let CALENDARS_URL = URL(fileURLWithPath: SUPPORT_DIR + "/calendars.json")

let args = CommandLine.arguments
let listOnly = args.contains("--list-calendars")
let doPurge = args.contains("--purge")
let onceOnly = args.contains("--once")

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(s)\n".data(using: .utf8)!)
}

// One long-lived engine — reused across every cycle so its warm store and
// per-mirror SnapshotGuard baseline persist. THIS is the fix for the fresh-
// process staleness that caused delete churn against eventually-consistent
// iCloud destinations.
let engine = MirrorEngine()

// ---- Access --------------------------------------------------------------
// Carries a value out of a Task without mutating a captured var, which older
// Swift toolchains reject ("mutation of captured var in concurrently-executing
// code") even though newer ones allow it under region-based isolation. The
// semaphore below orders the write before the read, so unchecked Sendable is
// an honest claim here rather than a silencer.
final class Holder<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

func requestAccessBlocking() -> Bool {
    let sema = DispatchSemaphore(value: 0)
    let granted = Holder(false)
    Task { granted.value = await engine.requestAccess(); sema.signal() }
    sema.wait()
    return granted.value
}

// ---- Outputs the UI reads ------------------------------------------------
// Publish the calendar list for the UI's pickers. The engine reliably holds
// Calendar access (it runs from launchd); the menu-bar UI is an accessory that
// can't dependably obtain its own EventKit prompt, so it reads this file.
func publishCalendars() {
    let arr = engine.calendars().map { c -> [String: Any] in
        ["title": c.title, "account": c.account, "identifier": c.identifier, "writable": c.writable]
    }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: CALENDARS_URL, options: .atomic)
    }
}

func writeStatus(paused: Bool, intervalSeconds: Int, results: [MirrorResult],
                 trigger: String = "floor", realtime: Bool = false, observing: Bool = false) {
    let mirrors = results.map { r -> [String: Any] in
        var d: [String: Any] = ["id": r.id, "name": r.name, "ok": r.ok,
            "created": r.created, "updated": r.updated, "unchanged": r.unchanged,
            "deleted": r.deleted, "total": r.total]
        if let e = r.error { d["error"] = e }
        if let n = r.note { d["note"] = n }
        return d
    }
    let o: [String: Any] = [
        "lastRun": ISO8601DateFormatter().string(from: Date()),
        "paused": paused, "intervalSeconds": intervalSeconds, "mirrors": mirrors,
        // Why this cycle ran, and whether change detection is actually up. Without
        // these the UI cannot tell a healthy realtime setup from one that has
        // silently fallen back to the schedule.
        "trigger": trigger, "realtime": realtime, "observing": observing,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: STATUS_URL, options: .atomic)
    }
}

// ---- Access gate ---------------------------------------------------------
guard requestAccessBlocking() else {
    log("ERROR: Calendar access not granted. System Settings > Privacy & Security > Calendars.")
    let cfg = ConfigStore.load(from: CONFIG_URL)
    writeStatus(paused: cfg.paused, intervalSeconds: cfg.intervalSeconds, results: cfg.mirrors.map {
        MirrorResult(id: $0.id, name: $0.name, ok: false, error: "Calendar access not granted") })
    exit(2)
}

publishCalendars()

// ---- One-shot modes ------------------------------------------------------
if listOnly {
    let arr = engine.calendars().map { c -> [String: Any] in
        ["title": c.title, "account": c.account, "identifier": c.identifier, "writable": c.writable]
    }
    let data = try! JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    exit(0)
}

if doPurge {
    let cfg = ConfigStore.load(from: CONFIG_URL)
    let removed = engine.purge(cfg)
    log("purge: removed \(removed) mirror-tagged events")
    exit(0)
}

// ---- One sync cycle ------------------------------------------------------
func runCycle(_ cfg: Config, trigger: SyncScheduler.Reason, observing: Bool) {
    publishCalendars()
    engine.refreshSources()
    if cfg.paused {
        log("paused (global) — skipping all mirrors.")
        writeStatus(paused: true, intervalSeconds: cfg.effectiveIntervalSeconds,
                    results: cfg.mirrors.map {
                        MirrorResult(id: $0.id, name: $0.name, ok: true, note: "paused") },
                    trigger: trigger.rawValue, realtime: cfg.realtime, observing: observing)
        return
    }
    let results = engine.syncAll(cfg, now: Date(), trigger: trigger, log: log)
    writeStatus(paused: false, intervalSeconds: cfg.effectiveIntervalSeconds, results: results,
                trigger: trigger.rawValue, realtime: cfg.realtime, observing: observing)
    let skipped = results.filter { $0.note == "unchanged" }.count
    let tail = skipped > 0 ? " · \(skipped) unchanged" : ""
    log("all mirrors done (\(results.filter { $0.ok }.count)/\(results.count) ok) [\(trigger.rawValue)]\(tail)")
}

if onceOnly {
    runCycle(ConfigStore.load(from: CONFIG_URL), trigger: .first, observing: false)
    exit(0)
}

// ---- Daemon loop ---------------------------------------------------------
// Cycles are driven by SyncScheduler, which weighs three things: calendar
// changes (debounced), a minimum gap between change-driven runs, and the
// scheduled floor. Config is re-read every pass, so interval/pause/realtime
// changes from the UI take effect without a restart.
//
// The floor never goes away. EKEventStoreChanged is best-effort, subscribed ICS
// feeds refresh silently, and sleep drops notifications outright — without a
// backstop a missed notification means a mirror stale forever with nothing to
// notice. In realtime mode the floor is pinned to 5 minutes and the configured
// interval steps aside.
log("cal-mirror daemon started (pid \(ProcessInfo.processInfo.processIdentifier))")

// The scheduler is touched from two threads: this loop, and whatever thread
// EventKit posts its change notification on.
let schedulerLock = NSLock()
nonisolated(unsafe) var scheduler = SyncScheduler()
let wake = DispatchSemaphore(value: 0)

nonisolated(unsafe) var observerToken: NSObjectProtocol?

func startObserving() {
    guard observerToken == nil else { return }
    observerToken = engine.observeChanges {
        let now = Date()
        schedulerLock.lock()
        let accepted = scheduler.noteChange(at: now)
        schedulerLock.unlock()
        // Only interrupt the wait for a change we actually intend to act on;
        // our own write echoing back should not even wake us.
        if accepted { wake.signal() }
    }
    log("realtime: observing calendar changes")
}

func stopObserving() {
    guard let token = observerToken else { return }
    engine.stopObserving(token)
    observerToken = nil
    log("realtime: stopped observing")
}

while true {
    let cfg = ConfigStore.load(from: CONFIG_URL)

    // Follow the config: realtime can be toggled from the UI at any time.
    if cfg.realtime && !cfg.paused { startObserving() } else { stopObserving() }
    let observing = observerToken != nil

    schedulerLock.lock()
    let decision = scheduler.decide(now: Date(), intervalSeconds: cfg.effectiveIntervalSeconds)
    schedulerLock.unlock()

    switch decision {
    case .sync(let reason):
        runCycle(cfg, trigger: reason, observing: observing)
        let done = Date()
        schedulerLock.lock()
        // Order matters: open the self-write window BEFORE clearing the pending
        // burst, so an echo landing in between is suppressed rather than
        // scheduling the cycle that just finished all over again.
        scheduler.noteWrite(at: done)
        scheduler.noteSyncFinished(at: done)
        schedulerLock.unlock()

    case .wait(let seconds):
        // A change signals the semaphore, so realtime cuts the wait short
        // rather than waiting out the whole floor.
        _ = wake.wait(timeout: .now() + seconds)
        // Collapse a burst into a single wake-up. Signals accumulate, so without
        // this a 200-event pull would spin the loop 200 times — each pass doing
        // nothing but re-deciding. Draining is safe because the decision comes
        // entirely from the scheduler's state, never from the semaphore count:
        // anything still pending is reflected in the next `decide`.
        while wake.wait(timeout: .now()) == .success {}
    }
}
