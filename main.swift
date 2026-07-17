// cal-mirror — one-way mirror of any Mac calendar into any other Mac calendar.
// Each configured "mirror" pairs a source calendar with a destination; the
// engine expands recurring source events into occurrences and upserts them
// into the destination, tagged with a per-mirror marker so the delete-sweep
// only ever touches that mirror's own copies. Multiple mirrors may target the
// same destination without colliding.
//
// Runtime settings come from config.json (written by the menu-bar UI); each
// run emits status.json for the UI. Recurring events are expanded (no RRULE
// translation); detached exceptions are already resolved by EventKit.
//
// Usage:  cal-mirror [--dry-run] [--list-calendars]

import EventKit
import Foundation

// ---- Markers -------------------------------------------------------------
let MARKER_SCHEME = "x-calmirror"          // event URL: x-calmirror:<mirrorId>|<key>
let HEARTBEAT_SCHEME = "x-calmirror-status" // event URL: x-calmirror-status:<mirrorId>

// ---- Paths ---------------------------------------------------------------
let SUPPORT_DIR = ("~/.local/cal-mirror" as NSString).expandingTildeInPath
let CONFIG_PATH = SUPPORT_DIR + "/config.json"
let STATUS_PATH = SUPPORT_DIR + "/status.json"

let dryRun = CommandLine.arguments.contains("--dry-run")
let verbose = dryRun || CommandLine.arguments.contains("--verbose")
let listOnly = CommandLine.arguments.contains("--list-calendars")
let now = Date()

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(s)\n".data(using: .utf8)!)
}

// ---- Config model --------------------------------------------------------
struct CalRef { var title: String; var account: String? }

// Per-mirror field projection: what each source field becomes in the copy.
// An absent `projection` block yields Projection() — the historical behavior
// (real title, location copied, no notes/alarms, source availability).
enum TitleMode { case copy, redact }
struct Projection {
    var title: TitleMode = .copy
    var titleText = "Busy"       // used when title == .redact
    var copyLocation = true
    var copyNotes = false
    var copyAlarms = false
    var busy = false             // availability: false = mirror source, true = force busy
}

struct Mirror {
    var id: String
    var name: String
    var source: CalRef
    var dest: CalRef
    var enabled = true
    var showHeartbeat = true
    var windowPastDays = 30.0
    var windowFutureDays = 365.0
    var projection = Projection()
    var legacyScheme: String?   // e.g. "x-jhmirror" — recognize pre-rename tags
}
struct Config { var paused = false; var intervalSeconds = 900; var mirrors: [Mirror] = [] }

// Per-event override tags typed into the SOURCE event's title. Fixed strings,
// matched case-insensitively, stripped from the copied title so they don't leak.
let TAG_SKIP = "#nomirror"      // don't mirror this event at all
let TAG_PRIVATE = "#private"    // force full redaction, even on a copy mirror
let TAG_PUBLIC = "#public"      // force full copy, even on a redacting mirror

func loadConfig() -> Config {
    var c = Config()
    guard let data = FileManager.default.contents(atPath: CONFIG_PATH),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return c }
    c.paused = o["paused"] as? Bool ?? false
    c.intervalSeconds = o["intervalSeconds"] as? Int ?? 900
    for m in (o["mirrors"] as? [[String: Any]] ?? []) {
        guard let id = m["id"] as? String,
              let src = m["source"] as? [String: Any], let srcTitle = src["title"] as? String,
              let dst = m["dest"] as? [String: Any], let dstTitle = dst["title"] as? String
        else { continue }
        var mir = Mirror(
            id: id,
            name: m["name"] as? String ?? id,
            source: CalRef(title: srcTitle, account: src["account"] as? String),
            dest: CalRef(title: dstTitle, account: dst["account"] as? String)
        )
        mir.enabled = m["enabled"] as? Bool ?? true
        mir.showHeartbeat = m["showHeartbeat"] as? Bool ?? true
        mir.windowPastDays = m["windowPastDays"] as? Double ?? 30
        mir.windowFutureDays = m["windowFutureDays"] as? Double ?? 365
        if let pj = m["projection"] as? [String: Any] {
            var p = Projection()
            if let t = pj["title"] as? String { p.title = (t == "redact") ? .redact : .copy }
            if let tt = pj["titleText"] as? String, !tt.isEmpty { p.titleText = tt }
            if let l = pj["location"] as? Bool { p.copyLocation = l }
            if let n = pj["notes"] as? Bool { p.copyNotes = n }
            if let a = pj["alarms"] as? Bool { p.copyAlarms = a }
            if let av = pj["availability"] as? String { p.busy = (av == "busy") }
            mir.projection = p
        }
        mir.legacyScheme = m["legacyScheme"] as? String
        c.mirrors.append(mir)
    }
    return c
}
let cfg = loadConfig()

// ---- Access --------------------------------------------------------------
let store = EKEventStore()
func requestAccess() -> Bool {
    let sema = DispatchSemaphore(value: 0)
    var granted = false
    store.requestFullAccessToEvents { ok, _ in granted = ok; sema.signal() }
    sema.wait()
    return granted
}

// ---- --list-calendars ----------------------------------------------------
if listOnly {
    guard requestAccess() else { log("ERROR: Calendar access not granted."); exit(2) }
    let arr = store.calendars(for: .event).map { c -> [String: Any] in
        ["title": c.title, "account": c.source.title,
         "identifier": c.calendarIdentifier, "writable": c.allowsContentModifications]
    }.sorted { ($0["account"] as! String, $0["title"] as! String) < ($1["account"] as! String, $1["title"] as! String) }
    let data = try! JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    exit(0)
}

// ---- Status output -------------------------------------------------------
struct MirrorResult {
    var id: String, name: String
    var ok: Bool, error: String? = nil
    var created = 0, updated = 0, unchanged = 0, deleted = 0
    var total: Int { created + updated + unchanged }
}
func writeStatus(paused: Bool, results: [MirrorResult]) {
    guard !dryRun else { return }
    let mirrors = results.map { r -> [String: Any] in
        var d: [String: Any] = ["id": r.id, "name": r.name, "ok": r.ok,
            "created": r.created, "updated": r.updated, "unchanged": r.unchanged,
            "deleted": r.deleted, "total": r.total]
        if let e = r.error { d["error"] = e }
        return d
    }
    let o: [String: Any] = [
        "lastRun": ISO8601DateFormatter().string(from: now),
        "paused": paused, "intervalSeconds": cfg.intervalSeconds, "mirrors": mirrors,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: STATUS_PATH), options: .atomic)
    }
}

// ---- Global pause --------------------------------------------------------
if cfg.paused {
    log("paused (global) — skipping all mirrors.")
    writeStatus(paused: true, results: cfg.mirrors.map { MirrorResult(id: $0.id, name: $0.name, ok: true) })
    exit(0)
}

guard requestAccess() else {
    log("ERROR: Calendar access not granted. System Settings > Privacy & Security > Calendars.")
    writeStatus(paused: false, results: cfg.mirrors.map {
        MirrorResult(id: $0.id, name: $0.name, ok: false, error: "Calendar access not granted") })
    exit(2)
}

let allCals = store.calendars(for: .event)

// Publish the calendar list for the UI's pickers. The engine reliably holds
// Calendar access (it runs from launchd); the menu-bar UI is an LSUIElement
// accessory that can't dependably obtain its own EventKit prompt, so it reads
// this file instead of touching EventKit at all. Written on every run,
// including --dry-run, since it's a read-only enumeration.
func publishCalendarList() {
    let arr = allCals.map { c -> [String: Any] in
        ["title": c.title, "account": c.source.title,
         "identifier": c.calendarIdentifier, "writable": c.allowsContentModifications]
    }.sorted { ($0["account"] as! String, $0["title"] as! String) < ($1["account"] as! String, $1["title"] as! String) }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: SUPPORT_DIR + "/calendars.json"), options: .atomic)
    }
}
publishCalendarList()

func findCalendar(_ ref: CalRef) -> EKCalendar? {
    if let acct = ref.account {
        if let c = allCals.first(where: { $0.title == ref.title && $0.source.title == acct }) { return c }
    }
    return allCals.first { $0.title == ref.title }
}

// ---- --purge: remove ALL mirror-tagged events from configured dests -------
if CommandLine.arguments.contains("--purge") {
    let wide = 800.0 * 86400
    var removed = 0
    for m in cfg.mirrors {
        guard let dest = findCalendar(m.dest) else { continue }
        let evs = store.events(matching: store.predicateForEvents(
            withStart: now.addingTimeInterval(-wide), end: now.addingTimeInterval(wide), calendars: [dest]))
        for ev in evs {
            if let sc = ev.url?.scheme, sc.hasPrefix("x-calmirror") || sc.hasPrefix("x-jhmirror") {
                if !dryRun { try? store.remove(ev, span: .thisEvent, commit: false) }
                removed += 1
            }
        }
    }
    if !dryRun { try? store.commit() }
    log("purge: removed \(removed) mirror-tagged events\(dryRun ? " (DRY RUN)" : "")")
    exit(0)
}

// ---- Marker helpers ------------------------------------------------------
func keyFor(_ ev: EKEvent) -> String {
    let start = Int((ev.startDate ?? now).timeIntervalSince1970)
    // Prefer the stable external identifier. Subscribed/feed calendars often
    // expose no external id (and an unstable eventIdentifier); the old fallback
    // to a random UUID re-keyed those events on every fetch, so their copies
    // churned +N/−N forever. Fall back to a deterministic content hash instead.
    let base: String
    if let ext = ev.calendarItemExternalIdentifier, !ext.isEmpty {
        base = ext
    } else {
        let end = Int((ev.endDate ?? ev.startDate ?? now).timeIntervalSince1970)
        base = "c:\(ev.title ?? "")#\(end)#\(ev.isAllDay ? 1 : 0)#\(ev.location ?? "")"
    }
    return Data("\(base)#\(start)".utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
// Delimiter is "~": unreserved per RFC 3986 (never percent-encoded) and absent
// from the base64url key alphabet, so it round-trips through EKEvent.url intact.
func markerURL(_ mirrorId: String, _ key: String) -> URL? { URL(string: "\(MARKER_SCHEME):\(mirrorId)~\(key)") }
// Returns (owningMirrorId, occurrenceKey) for a dest event, honoring legacy tags.
func ownerOf(_ ev: EKEvent, _ mirrors: [Mirror]) -> (id: String, key: String)? {
    guard let u = ev.url, let scheme = u.scheme else { return nil }
    let s = u.absoluteString.removingPercentEncoding ?? u.absoluteString
    guard let colon = s.firstIndex(of: ":") else { return nil }
    let opaque = String(s[s.index(after: colon)...])
    if scheme == MARKER_SCHEME {
        // primary delimiter "~"; tolerate "|" from the pre-fix builds
        guard let d = opaque.firstIndex(where: { $0 == "~" || $0 == "|" }) else { return nil }
        return (String(opaque[..<d]), String(opaque[opaque.index(after: d)...]))
    }
    if let m = mirrors.first(where: { $0.legacyScheme == scheme }) { return (m.id, opaque) }
    return nil
}

// True if `ev` is itself a cal-mirror artifact — a copy some mirror wrote, or a
// heartbeat banner. These are skipped as sources so no mirror ever re-mirrors
// another mirror's output (a copy-of-a-copy).
func isMirrorArtifact(_ ev: EKEvent) -> Bool {
    guard let sc = ev.url?.scheme else { return false }
    if sc.hasPrefix(MARKER_SCHEME) { return true }        // x-calmirror marker + x-calmirror-status heartbeat
    if ownerOf(ev, cfg.mirrors) != nil { return true }    // legacy markers (x-jhmirror, …)
    return cfg.mirrors.contains { ($0.legacyScheme.map { $0 + "-status" }) == sc }  // legacy heartbeat
}

// ---- Per-event override tags --------------------------------------------
// Scan a source title for the fixed control tags. `clean` is the title with
// every tag removed and surrounding whitespace collapsed — what we copy so the
// tag never leaks into the destination. When no tag is present, `clean` is the
// original title untouched (so we don't churn on stray whitespace).
func scanTags(_ title: String) -> (skip: Bool, forcePrivate: Bool, forcePublic: Bool, clean: String) {
    var skip = false, priv = false, pub = false, found = false
    var t = title
    for (tok, set) in [(TAG_SKIP, 0), (TAG_PRIVATE, 1), (TAG_PUBLIC, 2)] {
        while let r = t.range(of: tok, options: .caseInsensitive) {
            found = true
            switch set { case 0: skip = true; case 1: priv = true; default: pub = true }
            t.removeSubrange(r)
        }
    }
    guard found else { return (skip, priv, pub, title) }
    let clean = t.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    return (skip, priv, pub, clean)
}

// Order-independent fingerprint of an alarm set, so differ() can tell whether the
// copy's alarms already match the source's without re-saving every run.
func alarmSig(_ alarms: [EKAlarm]?) -> String {
    guard let a = alarms, !a.isEmpty else { return "" }
    return a.map { al -> String in
        if let d = al.absoluteDate { return "@\(Int(d.timeIntervalSince1970))" }
        return "r\(Int(al.relativeOffset))"
    }.sorted().joined(separator: ",")
}
func cloneAlarm(_ a: EKAlarm) -> EKAlarm {
    if let d = a.absoluteDate { return EKAlarm(absoluteDate: d) }
    return EKAlarm(relativeOffset: a.relativeOffset)
}

// ---- Per-mirror sync -----------------------------------------------------
func syncMirror(_ m: Mirror) -> MirrorResult {
    var r = MirrorResult(id: m.id, name: m.name, ok: true)
    guard let source = findCalendar(m.source) else {
        log("[\(m.id)] source '\(m.source.title)' not found"); r.ok = false; r.error = "Source not found"; return r
    }
    guard let dest = findCalendar(m.dest) else {
        log("[\(m.id)] dest '\(m.dest.title)' not found"); r.ok = false; r.error = "Destination not found"; return r
    }
    if source.calendarIdentifier == dest.calendarIdentifier {
        r.ok = false; r.error = "Source and destination are the same"; return r
    }
    guard dest.allowsContentModifications else {
        r.ok = false; r.error = "Destination is read-only"; return r
    }
    log("[\(m.id)] '\(source.title)' [\(source.source.title)] -> '\(dest.title)' [\(dest.source.title)]")

    let winStart = now.addingTimeInterval(-m.windowPastDays * 86400)
    let winEnd = now.addingTimeInterval(m.windowFutureDays * 86400)

    let srcEvents = store.events(matching:
        store.predicateForEvents(withStart: winStart, end: winEnd, calendars: [source]))
    var desired: [String: EKEvent] = [:]
    var skipped = 0, mirrored = 0
    // Deterministic order so that when two events hash to the same key (possible
    // for feed calendars with no external id — keyFor falls back to a content
    // hash), the collision suffix below is assigned the same way every run and
    // doesn't churn. Sorting by keyFor also groups colliding events together.
    for ev in srcEvents.sorted(by: { keyFor($0) < keyFor($1) }) {
        if isMirrorArtifact(ev) { mirrored += 1; continue }         // don't re-mirror a copy/heartbeat
        if scanTags(ev.title ?? "").skip { skipped += 1; continue }  // honor #nomirror
        let base = keyFor(ev)
        var key = base, n = 1
        while desired[key] != nil { key = "\(base)-\(n)"; n += 1 }   // '-' is base64url-safe, '~'-free
        desired[key] = ev
    }

    let dstEvents = store.events(matching:
        store.predicateForEvents(withStart: winStart.addingTimeInterval(-86400),
                                 end: winEnd.addingTimeInterval(86400), calendars: [dest]))
    var existing: [String: EKEvent] = [:]
    var heartbeatEvent: EKEvent?
    let legacyHB = m.legacyScheme.map { $0 + "-status" }
    for ev in dstEvents {
        if let sc = ev.url?.scheme, sc == HEARTBEAT_SCHEME || sc == legacyHB {
            // heartbeat belongs to this mirror only if id matches (new scheme) or legacy
            let opaque = ev.url!.absoluteString.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            if sc == legacyHB || opaque == m.id { heartbeatEvent = ev }
            continue
        }
        if let owner = ownerOf(ev, cfg.mirrors), owner.id == m.id { existing[owner.key] = ev }
    }
    log("[\(m.id)] source occ: \(srcEvents.count)  existing copies: \(existing.count)"
        + (skipped > 0 ? "  skipped(#nomirror): \(skipped)" : "")
        + (mirrored > 0 ? "  skipped(mirror-copies): \(mirrored)" : ""))

    // The single source of truth for what a copy should contain. Both differ()
    // and apply() read it, so the compare can never drift from the write (drift
    // would re-save every event forever). Per-event tags override the mirror's
    // projection here; structural fields — start/end, all-day, timezone — are
    // always copied verbatim because they define the block's shape, not content.
    struct Snapshot { var title: String; var location: String?; var notes: String?
                      var busy: EKEventAvailability; var alarmSig: String; var copyAlarms: Bool }
    func snapshot(_ src: EKEvent) -> Snapshot {
        let tags = scanTags(src.title ?? "")
        let p = m.projection
        let redact: Bool, loc: Bool, notes: Bool, alarms: Bool, busy: Bool
        if tags.forcePrivate {          // #private wins: nothing but a block
            redact = true; loc = false; notes = false; alarms = false; busy = true
        } else if tags.forcePublic {    // #public: replicate content, availability from source
            redact = false; loc = true; notes = true; alarms = p.copyAlarms; busy = false
        } else {
            redact = (p.title == .redact); loc = p.copyLocation; notes = p.copyNotes
            alarms = p.copyAlarms; busy = p.busy
        }
        let title = redact ? p.titleText
                           : (tags.clean.isEmpty ? "(no title)" : tags.clean)
        // Resolve availability. Subscribed feeds report .notSupported, which is
        // not a settable state — the destination coerces it to .busy on write, so
        // comparing against .notSupported would flag a diff on every run. Map it
        // to .busy so the copy round-trips and settles.
        let resolved: EKEventAvailability = busy ? .busy : src.availability
        let avail: EKEventAvailability = (resolved == .notSupported) ? .busy : resolved
        return Snapshot(
            title: title,
            location: loc ? src.location : nil,
            notes: notes ? src.notes : nil,
            busy: avail,
            alarmSig: alarms ? alarmSig(src.alarms) : "",
            copyAlarms: alarms)
    }
    // differ() and apply() take the precomputed snapshot and the marker key so
    // the snapshot is built once per event, and the url check compares against
    // the same key apply() writes (keys may be collision-suffixed).
    func differ(_ copy: EKEvent, _ src: EKEvent, _ s: Snapshot, key: String) -> Bool {
        copy.title != s.title || copy.startDate != src.startDate ||
        copy.endDate != src.endDate || copy.isAllDay != src.isAllDay ||
        (copy.location ?? "") != (s.location ?? "") ||
        (copy.notes ?? "") != (s.notes ?? "") ||
        copy.availability != s.busy ||
        alarmSig(copy.alarms) != s.alarmSig ||
        copy.url != markerURL(m.id, key)   // force-upgrade legacy markers
    }
    func apply(_ copy: EKEvent, _ src: EKEvent, _ s: Snapshot, key: String) {
        copy.title = s.title
        copy.startDate = src.startDate; copy.endDate = src.endDate
        copy.isAllDay = src.isAllDay; copy.timeZone = src.timeZone
        copy.location = s.location; copy.notes = s.notes
        copy.availability = s.busy
        copy.alarms?.forEach { copy.removeAlarm($0) }
        if s.copyAlarms, let alarms = src.alarms { for a in alarms { copy.addAlarm(cloneAlarm(a)) } }
        copy.url = markerURL(m.id, key); copy.calendar = dest
    }
    var pending = 0
    func maybeCommit(_ force: Bool = false) {
        guard !dryRun else { return }
        if force || pending >= 50 { try? store.commit(); pending = 0 }
    }

    for (key, src) in desired {
        let s = snapshot(src)                       // built once, shared by differ + apply
        if let copy = existing[key] {
            if differ(copy, src, s, key: key) {
                if !dryRun { apply(copy, src, s, key: key); try? store.save(copy, span: .thisEvent, commit: false); pending += 1 }
                r.updated += 1
            } else { r.unchanged += 1 }
        } else {
            if !dryRun { let c = EKEvent(eventStore: store); apply(c, src, s, key: key); try? store.save(c, span: .thisEvent, commit: false); pending += 1 }
            r.created += 1
        }
        maybeCommit()
    }
    for (key, copy) in existing where desired[key] == nil {
        if !dryRun { try? store.remove(copy, span: .thisEvent, commit: false); pending += 1 }
        r.deleted += 1
        maybeCommit()
    }
    maybeCommit(true)

    // ---- Heartbeat banner ----
    if !m.showHeartbeat {
        if let hb = heartbeatEvent, !dryRun { try? store.remove(hb, span: .thisEvent, commit: true) }
    } else if !dryRun {
        let dayStart = Calendar.current.startOfDay(for: now)
        let tf = DateFormatter(); tf.dateFormat = "h:mm a"
        let ev = heartbeatEvent ?? EKEvent(eventStore: store)
        ev.calendar = dest
        ev.isAllDay = true; ev.startDate = dayStart; ev.endDate = dayStart
        ev.title = "🗓️ \(m.name) ✓ \(r.total) events · \(tf.string(from: now))"
        ev.url = URL(string: "\(HEARTBEAT_SCHEME):\(m.id)")
        ev.notes = "Heartbeat for mirror '\(m.id)', auto-updated by cal-mirror.\n"
            + "Last run: \(ISO8601DateFormatter().string(from: now))\n"
            + "created=\(r.created) updated=\(r.updated) unchanged=\(r.unchanged) deleted=\(r.deleted)"
        try? store.save(ev, span: .thisEvent, commit: true)
    }
    log("[\(m.id)] done. +\(r.created) ~\(r.updated) =\(r.unchanged) -\(r.deleted)")
    return r
}

// ---- Guard: refuse reverse-direction pairs (A->B and B->A) ---------------
// Two mirrors pointing opposite directions between the same calendars would
// copy each other's copies forever. Resolve to calendar identifiers and refuse
// BOTH sides until the user removes one.
func resolvedPair(_ m: Mirror) -> (String, String)? {
    guard let s = findCalendar(m.source)?.calendarIdentifier,
          let d = findCalendar(m.dest)?.calendarIdentifier else { return nil }
    return (s, d)
}
var enabledPairs: [(id: String, pair: (String, String))] = []
for m in cfg.mirrors where m.enabled { if let p = resolvedPair(m) { enabledPairs.append((m.id, p)) } }
var reversedIds = Set<String>()
for a in enabledPairs {
    for b in enabledPairs where b.id != a.id {
        if b.pair.0 == a.pair.1 && b.pair.1 == a.pair.0 { reversedIds.insert(a.id); reversedIds.insert(b.id) }
    }
}

// ---- Run all enabled mirrors --------------------------------------------
var results: [MirrorResult] = []
for m in cfg.mirrors {
    if !m.enabled {
        results.append(MirrorResult(id: m.id, name: m.name, ok: true, error: "disabled")); continue
    }
    if reversedIds.contains(m.id) {
        log("[\(m.id)] REFUSED: reverse of another mirror — would create a copy loop")
        results.append(MirrorResult(id: m.id, name: m.name, ok: false,
            error: "Reverse of another mirror — refused to avoid a loop"))
        continue
    }
    results.append(syncMirror(m))
}
writeStatus(paused: false, results: results)
log("all mirrors done (\(results.filter { $0.ok }.count)/\(results.count) ok)\(dryRun ? "  (DRY RUN)" : "")")
