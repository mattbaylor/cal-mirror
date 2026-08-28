// Self-check of CalMirrorKit's pure logic (no EventKit access needed).
// Run: swift run cmk-check   — exits non-zero on any failure.
import Foundation
import CalMirrorKit

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") } else { print("  ✗ \(msg)"); failures += 1 }
}

print("Markers:")
let key = "MjV0ODdsOTYz-l4g_4766"   // base64url-style (contains - and _)
let url = Markers.copyURL(mirrorId: "jh", key: key)
check(url != nil, "copyURL builds a URL")
let owner = Markers.owner(of: url, mirrors: [])
check(owner?.id == "jh", "owner id parses")
check(owner?.key == key, "~ delimiter round-trips (key intact)")

let pipe = URL(string: "x-calmirror:jh|abc123")
check(Markers.owner(of: pipe, mirrors: [])?.key == "abc123", "legacy | delimiter still parses")

let m = Mirror(id: "jh", name: "JH", source: CalRef(title: "S"), dest: CalRef(title: "D"),
               legacyScheme: "x-jhmirror")
let legacy = URL(string: "x-jhmirror:deadbeef")
check(Markers.owner(of: legacy, mirrors: [m])?.id == "jh", "legacyScheme adoption")
check(Markers.owner(of: URL(string: "https://example.com"), mirrors: []) == nil, "untagged → nil")
check(Markers.owner(of: Markers.heartbeatURL(mirrorId: "jh"), mirrors: []) == nil, "heartbeat not a copy")
check(Markers.isMirrorTag(URL(string: "x-calmirror-status:jh")), "isMirrorTag heartbeat")
check(!Markers.isMirrorTag(URL(string: "https://example.com")), "isMirrorTag ignores http")

print("Config:")
let json = """
{ "mirrors": [ { "id": "work",
    "source": { "title": "Work" },
    "dest": { "title": "Work Copy", "account": "me@example.com" } } ] }
""".data(using: .utf8)!
do {
    let cfg = try JSONDecoder().decode(Config.self, from: json)
    check(cfg.intervalSeconds == 900, "intervalSeconds defaults to 900")
    check(cfg.paused == false, "paused defaults to false")
    check(cfg.mirrors.count == 1, "one mirror decoded")
    check(cfg.mirrors[0].name == "work", "name defaults to id")
    check(cfg.mirrors[0].enabled, "enabled defaults true")
    check(cfg.mirrors[0].windowFutureDays == 365, "windowFutureDays defaults 365")
    let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
    check(cfg == again, "encode → decode is stable")
} catch {
    check(false, "config decode threw: \(error)")
}

print("Projection + tags:")
// Absent projection block → historical defaults, and round-trips.
do {
    let cfg = try JSONDecoder().decode(Config.self, from: json)
    let p = cfg.mirrors[0].projection
    check(p.title == .copy && p.location && p.notes == .none && !p.alarms && p.availability == .source,
          "absent projection → historical defaults")
    let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
    check(cfg == again, "projection round-trips through encode/decode")
}
// A projection block decodes its fields; a bad value never nukes the config.
do {
    let j = """
    { "mirrors": [ { "id": "w", "source": {"title":"S"}, "dest": {"title":"D"},
      "projection": { "title": "redact", "titleText": "Out", "location": false,
        "notes": true, "availability": "busy", "custom": true, "alarms": "oops" } } ] }
    """.data(using: .utf8)!
    let cfg = try JSONDecoder().decode(Config.self, from: j)
    let p = cfg.mirrors[0].projection
    check(p.title == .redact && p.titleText == "Out" && !p.location && p.notes == .full
          && p.availability == .busy && p.custom, "projection fields decode")
    check(p.alarms == false, "malformed field falls back to default (no throw)")
}
// NotesMode: the wire format is a string now, but pre-tags-only configs wrote a
// Bool — both must decode, or an upgrade would silently change what gets copied.
func notesConfig(_ literal: String) -> Data {
    """
    { "mirrors": [ { "id": "w", "source": {"title":"S"}, "dest": {"title":"D"},
      "projection": { "notes": \(literal) } } ] }
    """.data(using: .utf8)!
}
do {
    let d = JSONDecoder()
    check(try d.decode(Config.self, from: notesConfig("true")).mirrors[0].projection.notes == .full,
          "legacy notes:true → .full")
    check(try d.decode(Config.self, from: notesConfig("false")).mirrors[0].projection.notes == .none,
          "legacy notes:false → .none")
    check(try d.decode(Config.self, from: notesConfig("\"tags\"")).mirrors[0].projection.notes == .tags,
          "notes:\"tags\" decodes")
    check(try d.decode(Config.self, from: notesConfig("\"full\"")).mirrors[0].projection.notes == .full,
          "notes:\"full\" decodes")
    check(try d.decode(Config.self, from: notesConfig("\"nonsense\"")).mirrors[0].projection.notes == .none,
          "unknown notes mode → .none, no throw")
} catch {
    check(false, "notes mode decode threw: \(error)")
}
// renderTagsOnly: tags are the payload; prose and control tags never cross.
check(renderTagsOnly("dentist #ref-conflict 3pm") == "#ref-conflict", "prose dropped, tag kept")
check(renderTagsOnly("no tags here") == nil, "no tags → nil (copy gets no notes)")
check(renderTagsOnly("#a details #b") == "#a #b", "several tags joined in source order")
check(renderTagsOnly("x #nomirror #private #public #keep") == "#keep", "control tags never copied")
check(renderTagsOnly("#-secret #+shown") == "#+shown", "#- dropped, #+ kept verbatim")
check(renderTagsOnly(nil) == nil, "nil notes → nil")
// scanNoteTags: control tags now live in NOTES, parsed as whole tokens.
check(scanNoteTags(nil).tokens.isEmpty && !scanNoteTags(nil).skip, "nil notes → no tags")
check(!scanNoteTags("just a plain note").skip, "prose without # → no tags")
check(scanNoteTags("Lunch #private").forcePrivate, "#private detected in notes")
check(scanNoteTags("sync #PUBLIC").forcePublic, "notes tag is case-insensitive")
check(scanNoteTags("hush #nomirror please").skip, "#nomirror detected in notes")
check(scanNoteTags("a#b not-a-tag").tokens.isEmpty, "# mid-word (a#b) is not a tag")
check(scanNoteTags("line one\n#ref-cal").tokens == ["#ref-cal"], "tag after newline; ends at whitespace")
check(scanNoteTags("bare # then #ok").tokens == ["#ok"], "bare # ignored; real tag kept")
check(scanNoteTags("#a #b #a").tokens == ["#a", "#b", "#a"], "multiple tags captured in order")

// Whole-token matching: #ref and #ref-cal are DISTINCT; +/- are part of the token.
let nt = scanNoteTags("#ref-cal #+agenda #-internal")
check(nt.matchesAny(["#ref-cal"]) && !nt.matchesAny(["#ref"]), "#ref does not match #ref-cal (whole token)")
check(nt.matchesAny(["ref-cal"]), "config tag without leading # is normalized")
check(nt.matchesAny(["#+agenda"]) && !nt.matchesAny(["#agenda"]), "+/- is part of the tag identity")
check(!nt.matchesAny([]) && !nt.matchesAny(["#nope"]), "no match → false")

// TagFilter.admits: include copies only matches; reject skips matches; reject wins over include is n/a (one mode).
let inc = TagFilter(mode: .include, tags: ["#ref"])
check(inc.admits(scanNoteTags("x #ref")) && !inc.admits(scanNoteTags("x #other")), "include: only tagged events admitted")
let rej = TagFilter(mode: .reject, tags: ["#skip"])
check(!rej.admits(scanNoteTags("x #skip")) && rej.admits(scanNoteTags("x #keep")), "reject: tagged events skipped")
check(TagFilter(mode: .include, tags: []).admits(scanNoteTags("anything")), "empty tag list → filter inactive (copy all)")

// renderCopiedNotes: control tags always stripped; others obey copyNotesTags + #±.
check(renderCopiedNotes("plain note", copyNotesTags: false) == "plain note", "no tags → notes untouched")
check(renderCopiedNotes("meet #nomirror", copyNotesTags: true) == "meet", "control tag stripped even when copying tags")
check(renderCopiedNotes("bring #gear", copyNotesTags: false) == "bring", "plain tag stripped by default")
check(renderCopiedNotes("bring #gear", copyNotesTags: true) == "bring #gear", "plain tag kept when copyNotesTags on")
check(renderCopiedNotes("a #-hide b", copyNotesTags: true) == "a b", "#- always hidden")
check(renderCopiedNotes("a #+show b", copyNotesTags: false) == "a #+show b", "#+ always kept, verbatim")
check(renderCopiedNotes("keep this\n#-drop", copyNotesTags: true) == "keep this", "untouched line preserved; tag-only line trimmed")
check(renderCopiedNotes("#nomirror", copyNotesTags: false) == nil, "notes that are only a stripped tag → nil")

// Config: tagFilter + copyNotesTags decode and round-trip; bad mode → no filter.
do {
    let j = """
    { "mirrors": [ { "id": "r", "source": {"title":"S"}, "dest": {"title":"D"},
      "tagFilter": { "mode": "include", "tags": ["#ref"] }, "copyNotesTags": true } ] }
    """.data(using: .utf8)!
    let cfg = try JSONDecoder().decode(Config.self, from: j)
    let m = cfg.mirrors[0]
    check(m.tagFilter?.mode == .include && m.tagFilter?.tags == ["#ref"], "tagFilter decodes")
    check(m.copyNotesTags, "copyNotesTags decodes")
    let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
    check(cfg == again, "tagFilter + copyNotesTags round-trip")
}
do {
    let j = """
    { "mirrors": [ { "id": "r", "source": {"title":"S"}, "dest": {"title":"D"},
      "tagFilter": { "mode": "bogus", "tags": ["#ref"] } } ] }
    """.data(using: .utf8)!
    let cfg = try JSONDecoder().decode(Config.self, from: j)
    check(cfg.mirrors[0].tagFilter == nil && !cfg.mirrors[0].copyNotesTags,
          "unknown mode → nil filter (copy all); copyNotesTags defaults false")
}

print("ReverseDetector:")
func P(_ id: String, _ s: String, _ d: String) -> ReverseDetector.Pair { .init(id: id, source: s, dest: d) }
// A->B and B->A: both flagged
do {
    let r = ReverseDetector.reversedIds([P("a", "A", "B"), P("b", "B", "A")])
    check(r == ["a", "b"], "A→B + B→A flags both")
}
// A->B and A->C: no reverse
check(ReverseDetector.reversedIds([P("a", "A", "B"), P("c", "A", "C")]).isEmpty, "same source, different dest → none")
// unrelated pair stays clear; only the reverse pair is flagged
do {
    let r = ReverseDetector.reversedIds([P("a", "A", "B"), P("b", "B", "A"), P("x", "C", "D")])
    check(r == ["a", "b"], "unrelated mirror not flagged")
}
check(ReverseDetector.reversedIds([P("a", "A", "B")]).isEmpty, "single mirror → none")
// 3-cycle (A→B→C→A) is NOT a direct reverse — documents the intentional limit
check(ReverseDetector.reversedIds([P("a", "A", "B"), P("b", "B", "C"), P("c", "C", "A")]).isEmpty,
      "3-way cycle not treated as a reverse pair (by design)")
// self-referential (source == dest) is not a reverse of itself
check(ReverseDetector.reversedIds([P("a", "A", "A")]).isEmpty, "source==dest is not a reverse")

print("Reconciler:")
func D(_ key: String, _ fp: String) -> Reconciler.Desired { .init(key: key, fingerprint: fp) }
func E(_ ref: Int, _ key: String, _ fp: String) -> Reconciler.Existing { .init(ref: ref, key: key, fingerprint: fp) }

// Steady state: one source event, one matching copy → match, no create/delete.
do {
    let p = Reconciler.plan(desired: [D("k1", "fpA")], existing: [E(0, "k1", "fpA")])
    check(p.match == [0: 0] && p.create.isEmpty && p.delete.isEmpty, "steady state → match only")
}
// New source event, no copy yet → create.
do {
    let p = Reconciler.plan(desired: [D("k1", "fpA")], existing: [])
    check(p.create == [0] && p.match.isEmpty && p.delete.isEmpty, "new event → create")
}
// Stale copy, source gone → delete.
do {
    let p = Reconciler.plan(desired: [], existing: [E(0, "k1", "fpA")])
    check(p.delete == [0] && p.match.isEmpty && p.create.isEmpty, "source gone → delete copy")
}
// THE ISSUE #2 BUG: identical-key duplicate twins collapse to one, extra deleted.
do {
    let p = Reconciler.plan(desired: [D("k1", "fpA")], existing: [E(0, "k1", "fpA"), E(1, "k1", "fpA")])
    check(p.match == [0: 0] && p.delete == [1] && p.create.isEmpty,
          "identical-key twins → keep one, delete the twin")
}
// Three-way identical-key pileup → keep lowest ref, delete the other two.
do {
    let p = Reconciler.plan(desired: [D("k1", "fpA")],
                            existing: [E(0, "k1", "fpA"), E(1, "k1", "fpA"), E(2, "k1", "fpA")])
    check(p.match == [0: 0] && p.delete == [1, 2], "3 identical-key copies → keep one")
}
// Divergent-key duplicate (same content, different keys) → fuzzy-match one, delete other.
do {
    let p = Reconciler.plan(desired: [D("k1", "fpA")], existing: [E(0, "kX", "fpA"), E(1, "kY", "fpA")])
    check(p.match.count == 1 && p.delete.count == 1 && p.create.isEmpty,
          "divergent-key dupes → adopt one by fingerprint, delete the rest (no new copy)")
}
// Fuzzy adoption: copy exists with a stale key but same content → reuse, don't create.
do {
    let p = Reconciler.plan(desired: [D("newkey", "fpA")], existing: [E(0, "oldkey", "fpA")])
    check(p.match == [0: 0] && p.create.isEmpty && p.delete.isEmpty,
          "stale-key copy adopted by fingerprint (no duplicate created)")
}
// Exact key wins over fingerprint even when a same-fp decoy is present.
do {
    let p = Reconciler.plan(desired: [D("k1", "fpA")], existing: [E(0, "k1", "fpA"), E(1, "kZ", "fpA")])
    check(p.match == [0: 0] && p.delete == [1], "exact-key match preferred; same-fp extra deleted")
}
// Reschedule (key + fp both change): old copy deleted, new created — never duplicated.
do {
    let p = Reconciler.plan(desired: [D("k2", "fpB")], existing: [E(0, "k1", "fpA")])
    check(p.create == [0] && p.delete == [0] && p.match.isEmpty, "rescheduled event → replace, not duplicate")
}
// Determinism: same inputs → identical plan.
do {
    let a = Reconciler.plan(desired: [D("k1", "f"), D("k2", "f")],
                            existing: [E(0, "k1", "f"), E(1, "k2", "f"), E(2, "k1", "f")])
    let b = Reconciler.plan(desired: [D("k1", "f"), D("k2", "f")],
                            existing: [E(0, "k1", "f"), E(1, "k2", "f"), E(2, "k1", "f")])
    check(a == b, "planner is deterministic")
}

print("Title prefix:")
do {
    let plain = Projection()
    check(plain.prefixed("Standup") == "Standup", "no prefix leaves the title alone")
    let pre = Projection(titlePrefix: "[Work]")
    check(pre.prefixed("Standup") == "[Work] Standup", "prefix is prepended with one space")
    check(Projection(titlePrefix: "  [Work]  ").prefixed("Standup") == "[Work] Standup",
          "surrounding whitespace is trimmed, not doubled")
    check(Projection(titlePrefix: "   ").prefixed("Standup") == "Standup",
          "a whitespace-only prefix counts as none")
    // The prefix rides on the REDACTED title too, so a busy-only mirror can
    // still say which mirror a block came from.
    let busy = Projection(title: .redact, titleText: "Busy", titlePrefix: "[Work]")
    check(busy.prefixed(busy.titleText) == "[Work] Busy", "prefix applies to a redacted title")

    // A prefix is never part of a preset.
    check(MirrorSummary.preset(of: Projection()) == .details, "no prefix → still the details preset")
    check(MirrorSummary.preset(of: pre) == .custom, "a prefix forces Custom")
    check(MirrorSummary.projection(pre).contains("prefixed"), "the summary names the prefix")

    // Absent in JSON → empty, and it round-trips.
    let j = """
    { "mirrors": [ { "id": "w", "source": {"title":"S"}, "dest": {"title":"D"},
      "projection": { "titlePrefix": "[Work]" } } ] }
    """.data(using: .utf8)!
    let cfg = try JSONDecoder().decode(Config.self, from: j)
    check(cfg.mirrors[0].projection.titlePrefix == "[Work]", "titlePrefix decodes")
    let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
    check(cfg == again, "titlePrefix round-trips")
    let absent = try JSONDecoder().decode(Config.self, from: json)
    check(absent.mirrors[0].projection.titlePrefix == "", "absent titlePrefix → empty (no change)")
}

print("SyncScheduler:")
do {
    let t0 = Date(timeIntervalSince1970: 1_756_000_000)
    func at(_ secs: TimeInterval) -> Date { t0.addingTimeInterval(secs) }
    let FLOOR = 300     // the 5-minute backstop realtime pins

    // Cold start.
    do {
        let s = SyncScheduler()
        check(s.decide(now: t0, intervalSeconds: FLOOR) == .sync(.first), "nothing has run yet → sync")
    }

    // The floor fires on its own, with no changes at all.
    do {
        var s = SyncScheduler()
        s.noteSyncFinished(at: t0)
        check(s.decide(now: at(120), intervalSeconds: FLOOR) == .wait(180), "idle → wait out the floor")
        check(s.decide(now: at(300), intervalSeconds: FLOOR) == .sync(.floor), "floor reached → sync")
        check(s.decide(now: at(900), intervalSeconds: FLOOR) == .sync(.floor), "long past the floor → sync")
    }

    // A change syncs once quiet, not immediately.
    do {
        var s = SyncScheduler()
        s.noteSyncFinished(at: t0)
        s.noteChange(at: at(100))
        check(s.decide(now: at(101), intervalSeconds: FLOOR) == .wait(9), "one change → wait out the debounce")
        check(s.decide(now: at(110), intervalSeconds: FLOOR) == .sync(.change), "debounce elapsed → sync")
    }

    // A burst collapses into ONE sync: each change restarts the quiet period.
    do {
        var s = SyncScheduler()
        s.noteSyncFinished(at: t0)
        for i in 0..<20 { s.noteChange(at: at(100 + Double(i))) }   // one a second for 20s
        check(s.decide(now: at(120), intervalSeconds: FLOOR) != .sync(.change),
              "still arriving → not yet")
        check(s.decide(now: at(129), intervalSeconds: FLOOR) == .sync(.change),
              "quiet for the debounce after the last one → one sync for the whole burst")
    }

    // ...but a slow drip can't defer forever: the cap wins.
    do {
        var s = SyncScheduler()
        s.noteSyncFinished(at: t0)
        var when = 100.0
        while when < 200 { s.noteChange(at: at(when)); when += 5 }   // never quiet for 10s
        check(s.decide(now: at(160), intervalSeconds: FLOOR) == .sync(.change),
              "maxDebounce reached → sync even though changes keep coming")
    }

    // Our own writes are ignored — this is what stops a sync triggering itself.
    do {
        var s = SyncScheduler()
        s.noteSyncFinished(at: t0)
        s.noteWrite(at: at(100))
        check(s.noteChange(at: at(101)) == false, "a change right after our write is our echo")
        check(s.decide(now: at(200), intervalSeconds: FLOOR) == .wait(100),
              "the echo did not schedule anything")
        check(s.noteChange(at: at(110)) == true, "past the window, changes count again")
    }

    // Change-driven syncs respect the minimum gap; the floor does not.
    do {
        var s = SyncScheduler(tuning: .init(debounce: 10, maxDebounce: 60, minGap: 60, selfWriteWindow: 5))
        s.noteSyncFinished(at: t0)
        s.noteChange(at: at(5))
        check(s.decide(now: at(20), intervalSeconds: FLOOR) == .wait(40),
              "debounced but inside minGap → wait out the gap")
        check(s.decide(now: at(60), intervalSeconds: FLOOR) == .sync(.change), "gap elapsed → sync")
    }
    do {
        // minGap must never suppress the backstop — it protects against exactly
        // the notification stream that would be suppressing it.
        var s = SyncScheduler(tuning: .init(debounce: 10, maxDebounce: 60, minGap: 600, selfWriteWindow: 5))
        s.noteSyncFinished(at: t0)
        check(s.decide(now: at(300), intervalSeconds: FLOOR) == .sync(.floor),
              "the floor outranks minGap")
    }

    // Finishing a cycle clears the burst — it has already seen those changes.
    do {
        var s = SyncScheduler()
        s.noteSyncFinished(at: t0)
        s.noteChange(at: at(100))
        s.noteSyncFinished(at: at(115))
        check(s.decide(now: at(130), intervalSeconds: FLOOR) == .wait(285),
              "after a cycle, only the floor is pending")
    }

    // A nonsense interval can't produce a hot loop.
    do {
        var s = SyncScheduler()
        s.noteSyncFinished(at: t0)
        check(s.decide(now: at(1), intervalSeconds: 0) == .wait(59), "interval is clamped to 60s")
        check(s.decide(now: at(60), intervalSeconds: -5) == .sync(.floor), "negative interval clamps too")
    }

    // Never a zero or negative wait, whatever the arithmetic.
    do {
        var s = SyncScheduler()
        s.noteSyncFinished(at: t0)
        s.noteChange(at: at(299.9))
        if case let .wait(w) = s.decide(now: at(299.95), intervalSeconds: FLOOR) {
            check(w >= 0.5, "waits are always positive")
        } else { check(true, "syncing instead of waiting is fine here") }
    }
}

print("HeartbeatPolicy:")
do {
    typealias HP = HeartbeatPolicy
    let now = Date(timeIntervalSince1970: 1_756_000_000)
    let yesterday = now.addingTimeInterval(-86400)

    // Healthy is silent: nothing written, and any earlier warning is cleared.
    check(HP.decide(enabled: true, health: .ok, existingTitle: nil,
                    mirrorName: "M", lastSuccess: nil, now: now) == .none,
          "healthy with no banner → write nothing")
    check(HP.decide(enabled: true, health: .ok, existingTitle: "⚠︎ old",
                    mirrorName: "M", lastSuccess: nil, now: now) == .remove,
          "recovering clears the standing warning")

    // A failure raises one.
    if case let .write(t) = HP.decide(enabled: true, health: .failing("Source not found"),
                                      existingTitle: nil, mirrorName: "Work Mirror",
                                      lastSuccess: nil, now: now) {
        check(t.contains("Work Mirror") && t.contains("Source not found"),
              "the warning names the mirror and the reason")
    } else { check(false, "a failure should write a banner") }

    // THE loop-safety rule: an unchanged warning must not be re-saved. Every
    // write posts an EventKit change notification, which is what event-driven
    // sync will key off.
    let standing = HP.title(mirrorName: "M", reason: "Source not found",
                            lastSuccess: nil, now: now)
    check(HP.decide(enabled: true, health: .failing("Source not found"),
                    existingTitle: standing, mirrorName: "M",
                    lastSuccess: nil, now: now) == .none,
          "an unchanged warning is NOT rewritten (no self-triggering write)")
    check(HP.decide(enabled: true, health: .failing("Destination is read-only"),
                    existingTitle: standing, mirrorName: "M",
                    lastSuccess: nil, now: now) != .none,
          "a changed reason does rewrite")

    // A deferral is not evidence of health either way.
    check(HP.decide(enabled: true, health: .unknown, existingTitle: nil,
                    mirrorName: "M", lastSuccess: nil, now: now) == .none,
          "deferred raises nothing")
    check(HP.decide(enabled: true, health: .unknown, existingTitle: "⚠︎ old",
                    mirrorName: "M", lastSuccess: nil, now: now) == .none,
          "deferred does NOT clear a standing warning")

    // Turning it off clears up — this is also what retires the old always-on
    // banners on the first upgrade cycle.
    check(HP.decide(enabled: false, health: .failing("x"), existingTitle: "⚠︎ old",
                    mirrorName: "M", lastSuccess: nil, now: now) == .remove,
          "disabled clears any banner (and migrates the old ones away)")
    check(HP.decide(enabled: false, health: .ok, existingTitle: nil,
                    mirrorName: "M", lastSuccess: nil, now: now) == .none,
          "disabled with nothing there does nothing")

    // The last-clean-sync date is what tells you how alarmed to be — but only
    // once it is old news.
    let dated = HP.title(mirrorName: "M", reason: "Source not found",
                         lastSuccess: yesterday, now: now)
    check(dated.contains("last synced"), "an older success is dated in the warning")
    let sameDay = HP.title(mirrorName: "M", reason: "Source not found",
                           lastSuccess: now, now: now)
    check(!sameDay.contains("last synced"), "a success earlier today adds no date")
    check(HP.dayLabel(now) == HP.dayLabel(now), "dayLabel is stable")
}

print("EventFilters:")
// Absent block → copies everything (the historical contract).
do {
    let cfg = try JSONDecoder().decode(Config.self, from: json)
    let f = cfg.mirrors[0].filters
    check(!f.isActive && f.activeRuleCount == 0, "absent filters block → no rules, copies everything")
    let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
    check(cfg == again, "filters round-trip through encode/decode")
}

let t0 = Date(timeIntervalSince1970: 1_756_000_000)
func ev(_ title: String = "Standup", startHour: Int = 10, minutes: Int = 60,
        allDay: Bool = false, free: Bool = false, canceled: Bool = false,
        reply: FilterableEvent.Reply = .none, dayOffset: Int = 0) -> FilterableEvent {
    let day = Calendar.current.startOfDay(for: t0.addingTimeInterval(Double(dayOffset) * 86400))
    let s = day.addingTimeInterval(Double(startHour) * 3600)
    return FilterableEvent(title: title, start: s, end: s.addingTimeInterval(Double(minutes) * 60),
                           isAllDay: allDay, isFree: free, isCanceled: canceled, reply: reply)
}

// Invitation state.
check(EventFilters(declined: true).admits(ev(reply: .declined)) == false, "declined → skipped")
check(EventFilters(declined: true).admits(ev(reply: .accepted)), "accepted survives the declined rule")
check(EventFilters(unanswered: true).admits(ev(reply: .pending)) == false, "pending invite → skipped")
check(EventFilters(unanswered: true).admits(ev(reply: .none)),
      "self-made event (no attendees) survives the unanswered rule")
check(EventFilters(canceled: true).admits(ev(canceled: true)) == false, "canceled → skipped")
check(EventFilters().admits(ev(canceled: true, reply: .declined)),
      "all-default filters admit even a declined, canceled event")

// Shape.
check(EventFilters(allDay: true).admits(ev(allDay: true)) == false, "all-day → skipped")
check(EventFilters(free: true).admits(ev(free: true)) == false, "free event → skipped")
check(EventFilters(shorterThanMinutes: 15).admits(ev(minutes: 10)) == false, "shorter-than → skipped")
check(EventFilters(shorterThanMinutes: 15).admits(ev(minutes: 30)), "long enough survives")
check(EventFilters(longerThanMinutes: 240).admits(ev(minutes: 600)) == false, "longer-than → skipped")

// Title substring, case-insensitive.
let reject = EventFilters(title: .init(mode: .reject, patterns: ["lunch", "Focus time"]))
check(reject.admits(ev("Team Lunch")) == false, "reject matches case-insensitively")
check(reject.admits(ev("Standup")), "reject leaves non-matching titles alone")
let only = EventFilters(title: .init(mode: .include, patterns: ["game"]))
check(only.admits(ev("Varsity Game")), "include keeps a match")
check(only.admits(ev("Standup")) == false, "include drops a non-match")
check(EventFilters(title: .init(mode: .reject, patterns: [])).admits(ev("anything")),
      "empty pattern list constrains nothing")

// Time of day — overlap, not containment.
let work = EventFilters(hours: .init(mode: .keep, startMinute: 8 * 60, endMinute: 18 * 60))
check(work.admits(ev(startHour: 10)), "10am event inside an 8-6 keep-window")
check(work.admits(ev(startHour: 7, minutes: 120)), "7-9am event kept — it OVERLAPS the window")
check(work.admits(ev(startHour: 20)) == false, "8pm event outside the window → skipped")
check(work.admits(ev(startHour: 3, allDay: true)),
      "all-day events are exempt from an hours rule (use the all-day switch)")
let evenings = EventFilters(hours: .init(mode: .drop, startMinute: 8 * 60, endMinute: 18 * 60))
check(evenings.admits(ev(startHour: 20)), "drop-mode keeps what falls outside the window")
check(evenings.admits(ev(startHour: 10)) == false, "drop-mode skips what falls inside")
// A window that wraps midnight (overnight on-call).
let overnight = EventFilters(hours: .init(mode: .keep, startMinute: 22 * 60, endMinute: 6 * 60))
check(overnight.admits(ev(startHour: 23)), "wrapped window keeps 11pm")
check(overnight.admits(ev(startHour: 2)), "wrapped window keeps 2am")
check(overnight.admits(ev(startHour: 12)) == false, "wrapped window skips midday")

// Day-of-week restriction.
do {
    let sunday = Calendar.current.component(.weekday, from: Calendar.current.startOfDay(for: t0))
    let onlyThatDay = EventFilters(hours: .init(mode: .keep, startMinute: 0, endMinute: 24 * 60,
                                                days: [sunday]))
    check(onlyThatDay.admits(ev(startHour: 10)), "event on an allowed weekday is kept")
    check(onlyThatDay.admits(ev(startHour: 10, dayOffset: 1)) == false,
          "event on a disallowed weekday is skipped")
}

// Rule counting drives the UI summary.
check(EventFilters(declined: true, canceled: true, allDay: true).activeRuleCount == 3,
      "activeRuleCount counts each enabled rule")
check(EventFilters(hours: .init(mode: .keep, startMinute: 0, endMinute: 24 * 60)).activeRuleCount == 0,
      "an all-day every-day window counts as no rule")

// Lenient decoding: a malformed rule degrades to no rule, never a half-set one.
do {
    let bad = """
    { "mirrors": [ { "id": "x", "source": { "title": "S" }, "dest": { "title": "D" },
      "filters": { "declined": true, "title": { "mode": "nonsense", "patterns": ["a"] },
                   "shorterThanMinutes": -5 } } ] }
    """.data(using: .utf8)!
    let cfg = try JSONDecoder().decode(Config.self, from: bad)
    let f = cfg.mirrors[0].filters
    check(f.declined, "good keys survive alongside a malformed one")
    check(f.title == nil, "unknown title mode → no title rule (not a half-set one)")
    check(f.shorterThanMinutes == 0, "negative duration clamps to off")
}

print("Summaries:")
check(MirrorSummary.clock(480) == "8am", "480 → 8am")
check(MirrorSummary.clock(1050) == "5:30pm", "1050 → 5:30pm")
check(MirrorSummary.clock(0) == "12am", "midnight → 12am")
check(MirrorSummary.clock(12 * 60) == "12pm", "noon → 12pm")
check(MirrorSummary.dayList([2, 3, 4, 5, 6]) == "Mon–Fri", "contiguous weekdays collapse to a range")
check(MirrorSummary.dayList([1, 7]) == "Sun, Sat", "non-contiguous days are listed")
check(MirrorSummary.dayList([1, 2, 3, 4, 5, 6, 7]) == "every day", "all seven → every day")

check(MirrorSummary.projection(Projection()) == "Title and location", "default projection summary")
check(MirrorSummary.projection(Projection(title: .redact, location: false, availability: .busy)) == "Busy only",
      "busy preset summary")
check(MirrorSummary.projection(Projection(notes: .tags, custom: true)).contains("tags only"),
      "custom projection lists its parts")

check(MirrorSummary.selection(EventFilters(), tagFilter: nil) == "Every event",
      "no rules → Every event")
check(MirrorSummary.selection(EventFilters(declined: true, allDay: true), tagFilter: nil)
        == "Skips declined, all-day", "skip list reads as prose")
do {
    let f = EventFilters(declined: true, allDay: true,
                         hours: .init(mode: .keep, startMinute: 8 * 60, endMinute: 18 * 60))
    check(MirrorSummary.selection(f, tagFilter: TagFilter(mode: .include, tags: ["#ref"]))
            == "Skips declined, all-day · 8am–6pm · only #ref", "full selection summary")
}

// The list row's second line: silent for an ordinary mirror, loud for an odd one.
do {
    let plain = Mirror(id: "a", name: "A", source: CalRef(title: "S"), dest: CalRef(title: "D"))
    check(MirrorSummary.delta(plain) == nil, "a plain copy-everything mirror has no delta line")
    var odd = plain
    odd.projection = Projection(notes: .tags, custom: true)
    odd.filters = EventFilters(declined: true)
    check(MirrorSummary.delta(odd) == "tags only · 1 rule",
          "delta is terse: diverging projection bits, then a rule count")
    var busy = plain
    busy.projection = Projection(title: .redact, location: false, availability: .busy)
    check(MirrorSummary.delta(busy) == "Busy only", "a preset mirror names its preset")
}

print("Config write-back:")
// config.json is hand-editable, so an inactive block must not be spelled out as
// defaults — and absent must decode identically to all-default.
do {
    var m = Mirror(id: "x", name: "X", source: CalRef(title: "S"), dest: CalRef(title: "D"))
    let enc = JSONEncoder()
    let bare = String(data: try enc.encode(m), encoding: .utf8)!
    check(!bare.contains("filters"), "an inactive filters block is not written")
    check(!bare.contains("tagFilter"), "an absent tagFilter is not written")
    check(!bare.contains("copyNotesTags"), "a false copyNotesTags is not written")

    m.filters = EventFilters(declined: true)
    m.tagFilter = TagFilter(mode: .include, tags: ["#ref"])
    m.copyNotesTags = true
    let full = String(data: try enc.encode(m), encoding: .utf8)!
    check(full.contains("filters") && full.contains("tagFilter") && full.contains("copyNotesTags"),
          "active blocks ARE written")
    let back = try JSONDecoder().decode(Mirror.self, from: try enc.encode(m))
    check(back == m, "an active mirror round-trips unchanged")

    // An empty tag list means the filter constrains nothing, so it's dropped —
    // and comes back as nil, which decodes to the same behavior.
    var empty = m
    empty.tagFilter = TagFilter(mode: .include, tags: [])
    let e2 = try JSONDecoder().decode(Mirror.self, from: try enc.encode(empty))
    check(e2.tagFilter == nil, "an empty tagFilter drops to nil (same behavior, less noise)")
}

print("SnapshotGuard:")
func isSkip(_ d: SnapshotGuard.Decision) -> Bool { if case .skip = d { return true }; return false }
check(SnapshotGuard.decide(stabilized: true,  count: 441, lastKnown: 441) == .proceed, "stable, matching count → proceed")
check(SnapshotGuard.decide(stabilized: true,  count: 441, lastKnown: nil) == .proceed, "stable, first run → proceed")
check(SnapshotGuard.decide(stabilized: true,  count: 0,   lastKnown: nil) == .proceed, "stable, first run, empty dest → proceed (initial populate)")
check(isSkip(SnapshotGuard.decide(stabilized: false, count: 441, lastKnown: 441)), "unsettled view → skip")
check(isSkip(SnapshotGuard.decide(stabilized: true,  count: 0,   lastKnown: 441)), "collapsed to 0 vs known 441 → skip (stale)")
check(isSkip(SnapshotGuard.decide(stabilized: true,  count: 50,  lastKnown: 441)), "collapsed to <25% → skip (stale)")
check(SnapshotGuard.decide(stabilized: true, count: 430, lastKnown: 441) == .proceed, "minor drop (deletions) → proceed")
check(SnapshotGuard.decide(stabilized: true, count: 1, lastKnown: 3) == .proceed, "tiny baseline not treated as collapse")

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
