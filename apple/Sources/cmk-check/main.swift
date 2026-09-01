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

print("SourceDigest:")
do {
    func d(_ k: String, _ f: String) -> Reconciler.Desired { .init(key: k, fingerprint: f) }
    let a = [d("k1", "fpA"), d("k2", "fpB")]
    check(SourceDigest.of(a) == SourceDigest.of(a), "same input → same digest")
    check(SourceDigest.of(a) == SourceDigest.of(a.reversed()),
          "order-independent — EventKit's ordering must not look like a change")
    check(SourceDigest.of(a) != SourceDigest.of([d("k1", "fpA")]),
          "a removed event changes the digest")
    check(SourceDigest.of(a) != SourceDigest.of([d("k1", "fpA"), d("k2", "fpC")]),
          "a moved event changes the digest (fingerprint carries time)")
    check(SourceDigest.of(a) != SourceDigest.of([d("k1", "fpA"), d("k3", "fpB")]),
          "a re-keyed event changes the digest")
    check(SourceDigest.of([]) == SourceDigest.of([]), "empty is stable")
    check(SourceDigest.of([]) != SourceDigest.of(a), "empty differs from non-empty")
    // The separator matters: without it, ("ab","c") and ("a","bc") would collide.
    check(SourceDigest.of([d("ab", "c")]) != SourceDigest.of([d("a", "bc")]),
          "field boundaries are respected")
}

print("Config.realtime:")
do {
    // A fresh config gets realtime; a decoded one that predates the key does not.
    // Upgrading must never silently change how an existing setup syncs.
    check(Config().realtime, "a newly constructed config has realtime on")
    let old = try JSONDecoder().decode(Config.self, from: json)
    check(!old.realtime, "a config without the key decodes to realtime OFF")
    check(old.effectiveIntervalSeconds == old.intervalSeconds,
          "scheduled mode uses the configured interval")
    var rt = old; rt.realtime = true
    check(rt.effectiveIntervalSeconds == Config.realtimeFloorSeconds,
          "realtime pins the floor, whatever the configured interval says")
    let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(rt))
    check(back.realtime, "realtime round-trips")
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

print("Destination dedupe:")
do {
    var c = DestinationClaims()
    // First mirror to ask for a block gets it; a second asking for the same
    // block in the same destination is told no.
    check(c.claim(dest: "DEST", fingerprint: "Busy|9|10|0"), "first claim wins")
    check(!c.claim(dest: "DEST", fingerprint: "Busy|9|10|0"), "an identical block is refused")

    // THE safety property: mirrors that redact differently fingerprint
    // differently, so a busy-only mirror can never suppress a full-detail copy.
    check(c.claim(dest: "DEST", fingerprint: "Standup|9|10|0"),
          "a differently projected copy of the same slot still gets written")

    // Same block, different destination, is a different question entirely.
    check(c.claim(dest: "OTHER", fingerprint: "Busy|9|10|0"),
          "the same block in another destination is unaffected")

    // Two blocks that only differ by time do not collide.
    check(c.claim(dest: "DEST", fingerprint: "Busy|11|12|0"), "a different slot is its own claim")

    // Reading must not take.
    var d = DestinationClaims()
    check(!d.isClaimed(dest: "D", fingerprint: "F"), "nothing is claimed to begin with")
    check(d.claim(dest: "D", fingerprint: "F"), "claiming works after a peek")
    check(d.isClaimed(dest: "D", fingerprint: "F"), "and the peek then sees it")

    // The switch has to survive a save/load round trip, and must default off so
    // an existing setup never changes what it writes on upgrade.
    let enc = JSONEncoder(), dec = JSONDecoder()
    let on = Config(dedupeDestinations: true, mirrors: [])
    if let d = try? enc.encode(on), let back = try? dec.decode(Config.self, from: d) {
        check(back.dedupeDestinations, "dedupeDestinations round-trips")
    } else { check(false, "dedupeDestinations round-trips") }
    if let d = "{\"mirrors\":[]}".data(using: .utf8),
       let old = try? dec.decode(Config.self, from: d) {
        check(!old.dedupeDestinations, "absent → off (an upgrade changes nothing)")
    } else { check(false, "absent → off (an upgrade changes nothing)") }

    // The separator must not let two halves run together into a false match.
    var e = DestinationClaims()
    _ = e.claim(dest: "a", fingerprint: "bc")
    check(e.claim(dest: "ab", fingerprint: "c"),
          "dest and fingerprint cannot be confused for one another")
}

print("Source link:")
do {
    let https = URL(string: "https://zoom.us/j/12345")!
    check(withSourceLink(nil, https) == "https://zoom.us/j/12345",
          "no notes → the link becomes the notes")
    check(withSourceLink("Agenda attached", https) == "Agenda attached\n\nhttps://zoom.us/j/12345",
          "appended as its own trailing line")
    check(withSourceLink("Notes", nil) == "Notes", "no link → notes untouched")
    check(withSourceLink(nil, nil) == nil, "no notes and no link → nil")

    // Only followable links. An event's url can hold a message: reference to the
    // invitation mail or a local file, and neither resolves for anyone the
    // destination is shared with — an unfollowable link is just a leak.
    check(withSourceLink("Notes", URL(string: "message://%3c123@mail%3e")!) == "Notes",
          "message: links are not carried")
    check(withSourceLink("Notes", URL(string: "file:///Users/me/x.txt")!) == "Notes",
          "file: links are not carried")
    check(withSourceLink(nil, URL(string: "http://example.com/e")!) == "http://example.com/e",
          "plain http is carried")

    // Invitations routinely put the meeting URL in the body AND the url field;
    // printing it twice makes the copy look broken.
    let already = "Join here: https://zoom.us/j/12345 — see you then"
    check(withSourceLink(already, https) == already, "a link already in the notes is not repeated")

    // Idempotent: rendering the same source twice gives the same notes, which is
    // what keeps differ() from rewriting the copy every cycle.
    let once = withSourceLink("Agenda", https)
    check(withSourceLink(once, https) == once, "applying twice changes nothing")

    // Not part of any preset, and named in the summaries.
    let p = Projection(sourceLink: true)
    check(MirrorSummary.preset(of: p) == .custom, "a source link forces Custom")
    check(MirrorSummary.projection(p).contains("source link"), "the summary names it")
    check(MirrorSummary.preset(of: Projection()) == .details, "absent → still the details preset")

    // Absent in JSON → off, and it round-trips.
    let j = """
    { "mirrors": [ { "id": "w", "source": {"title":"S"}, "dest": {"title":"D"},
      "projection": { "sourceLink": true } } ] }
    """.data(using: .utf8)!
    let cfg = try JSONDecoder().decode(Config.self, from: j)
    check(cfg.mirrors[0].projection.sourceLink, "sourceLink decodes")
    let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
    check(cfg == again, "sourceLink round-trips")
    let absent = try JSONDecoder().decode(Config.self, from: json)
    check(!absent.mirrors[0].projection.sourceLink, "absent sourceLink → off (no change)")
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

print("RequestPolicy:")
// The horizon bounds are product decisions, not preferences, so nothing may get
// past them — not the initializer, not a later assignment, not a hand-edited file.
check(RequestPolicy().horizonDays == 14, "the default horizon is a fortnight")
check(RequestPolicy(horizonDays: 0).horizonDays == 2, "a horizon below two days clamps up")
check(RequestPolicy(horizonDays: 400).horizonDays == 45, "a horizon beyond 45 days clamps down")
do {
    var stretched = RequestPolicy()
    stretched.horizonDays = 90
    check(stretched.horizonDays == 45, "assigning past the ceiling clamps too")
}
do {
    let junk = """
    { "horizonDays": 90, "weekdays": ["mon", "funday"], "minNoticeHours": -4,
      "align": 900, "slotMinutes": 0 }
    """.data(using: .utf8)!
    let p = try JSONDecoder().decode(RequestPolicy.self, from: junk)
    check(p.horizonDays == 45, "an out-of-range horizon in JSON clamps on decode")
    check(p.weekdays == [.mon], "an unknown weekday name is dropped, the rest survive")
    check(p.minNoticeHours == 0, "negative notice clamps to none")
    check(p.align == 60, "an absurd alignment clamps to the hour")
    check(p.slotMinutes == 1, "a zero-length slot clamps to something offerable")
    check(p.maxPerDay == 4, "an absent field takes its default rather than throwing")
}
do {
    let p = RequestPolicy(lunch: .init(), blackout: ["2026-09-10"], timeZone: "America/Denver")
    let data = try JSONEncoder().encode(p)
    check(try JSONDecoder().decode(RequestPolicy.self, from: data) == p, "a policy round-trips through encode/decode")
    check(String(data: data, encoding: .utf8)!.contains("\"mon\""), "weekdays are written as names, not Calendar numbers")
    check(RequestPolicy.Weekday.mon.calendarWeekday == 2, "mon is Calendar's 2 (Sunday is 1)")
    check(RequestPolicy(timeZone: "Mars/Olympus").resolvedTimeZone == nil, "an unknown zone resolves to nil, not to the device's own")
}

print("SlotDeriver:")
// Everything below is America/Denver, because the DST checks further down need a
// real zone with a real transition and mixing zones would only hide mistakes.
let denver = TimeZone(identifier: "America/Denver")!
var mtnCal = Calendar(identifier: .gregorian)
mtnCal.timeZone = denver
func mtn(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    mtnCal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}
let utcISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()
func iso(_ d: Date) -> String { utcISO.string(from: d) }
func localHours(_ slots: [Slot]) -> [Int] { slots.map { mtnCal.component(.hour, from: $0.start) } }
func onDay(_ slots: [Slot], _ mo: Int, _ d: Int) -> [Slot] {
    slots.filter { mtnCal.component(.month, from: $0.start) == mo && mtnCal.component(.day, from: $0.start) == d }
}
// Hourly 9–5, every rule switched off, so each check below turns exactly one on.
// `weekdays` narrows to a single day where a test only cares about one; the
// horizon floor is two days and clamping is not negotiable.
func reqPolicy(horizonDays: Int = 2, minNoticeHours: Int = 0, slotMinutes: Int = 60,
               align: Int = 60, bufferMinutes: Int = 0, maxPerDay: Int = 24,
               starts: String = "09:00", ends: String = "17:00",
               lunch: RequestPolicy.Lunch? = nil,
               weekdays: [RequestPolicy.Weekday] = RequestPolicy.Weekday.allCases,
               blackout: [String] = []) -> RequestPolicy {
    RequestPolicy(horizonDays: horizonDays, minNoticeHours: minNoticeHours,
                  slotMinutes: slotMinutes, align: align, bufferMinutes: bufferMinutes,
                  maxPerDay: maxPerDay, day: .init(starts: starts, ends: ends),
                  lunch: lunch, weekdays: weekdays, blackout: blackout,
                  timeZone: "America/Denver")
}
let wed = mtn(2026, 9, 2)   // Wednesday, local midnight

do {
    let plain = SlotDeriver.derive(policy: reqPolicy(weekdays: [.wed]), busy: [], now: wed)
    check(localHours(plain) == [9, 10, 11, 12, 13, 14, 15, 16], "a 9–5 day at hourly slots runs 9am to 4pm local")
    check(plain.last?.end == mtn(2026, 9, 2, 17), "the last slot ends exactly when the day does")
    check(SlotDeriver.derive(policy: reqPolicy(slotMinutes: 45, align: 30, starts: "09:15",
                                               ends: "11:00", weekdays: [.wed]),
                             busy: [], now: wed).first?.start == mtn(2026, 9, 2, 9, 30),
          "a 9:15 start still lands on the :00/:30 grid, never on :15")
    var badZone = reqPolicy(weekdays: [.wed]); badZone.timeZone = "Mars/Olympus"
    check(SlotDeriver.derive(policy: badZone, busy: [], now: wed).isEmpty,
          "an unknown zone offers nothing rather than guessing at the device's own")
}

// Buffers. A 10–11 meeting with 15 minutes either side eats the half-hours that
// butt up against it, and leaves the ones clear of it alone.
do {
    let p = reqPolicy(slotMinutes: 30, align: 30, bufferMinutes: 15, ends: "12:00", weekdays: [.wed])
    let meeting = [BusyInterval(start: mtn(2026, 9, 2, 10), end: mtn(2026, 9, 2, 11))]
    let got = Set(SlotDeriver.derive(policy: p, busy: meeting, now: wed).map(\.start))
    check(!got.contains(mtn(2026, 9, 2, 9, 30)), "buffer excludes the slot butting up against a meeting")
    check(!got.contains(mtn(2026, 9, 2, 11)), "buffer excludes the slot right after it too")
    check(got.contains(mtn(2026, 9, 2, 9)), "a slot clear of the buffer survives")
    check(got.contains(mtn(2026, 9, 2, 11, 30)), "and so does the one on the far side")
}
// With no buffer, a gap exactly one slot wide is offered — the boundary is
// half-open, so touching a busy interval is not overlapping it.
do {
    let p = reqPolicy(slotMinutes: 30, align: 30, ends: "12:00", weekdays: [.wed])
    let busy = [BusyInterval(start: mtn(2026, 9, 2, 9), end: mtn(2026, 9, 2, 9, 30)),
                BusyInterval(start: mtn(2026, 9, 2, 10), end: mtn(2026, 9, 2, 12))]
    check(SlotDeriver.derive(policy: p, busy: busy, now: wed).map(\.start) == [mtn(2026, 9, 2, 9, 30)],
          "a gap exactly one slot wide is offered, and nothing else is")
}

// Minimum notice.
do {
    let p = reqPolicy(minNoticeHours: 12, weekdays: [.wed])
    check(localHours(SlotDeriver.derive(policy: p, busy: [], now: mtn(2026, 9, 2))) == [12, 13, 14, 15, 16],
          "notice drops the imminent slots and keeps the rest")
    check(SlotDeriver.derive(policy: p, busy: [], now: mtn(2026, 9, 2, 8)).isEmpty,
          "twelve hours' notice asked at 8am empties the whole day")
}

// maxPerDay. Four consecutive morning slots would say "and then the afternoon
// filled up"; four spread across the day say nothing about the twenty behind them.
do {
    let four = SlotDeriver.derive(policy: reqPolicy(maxPerDay: 4, weekdays: [.wed]), busy: [], now: wed)
    check(four.count == 4, "maxPerDay caps the day")
    check(localHours(four) == [9, 11, 14, 16], "the cap is spread across the day, not taken off the front")
    check(localHours(SlotDeriver.derive(policy: reqPolicy(maxPerDay: 1, weekdays: [.wed]), busy: [], now: wed)) == [9],
          "a cap of one still offers something")
    check(SlotDeriver.derive(policy: reqPolicy(maxPerDay: 0, weekdays: [.wed]), busy: [], now: wed).isEmpty,
          "a cap of zero offers nothing at all")
}

// Blackout dates and the weekday filter.
do {
    let p = reqPolicy(horizonDays: 3, weekdays: [.wed, .thu], blackout: ["2026-09-03"])
    let days = Set(SlotDeriver.derive(policy: p, busy: [], now: wed).map { mtnCal.component(.day, from: $0.start) })
    check(days == [2], "a blackout date is removed entirely")
}
do {
    let week = SlotDeriver.derive(policy: reqPolicy(horizonDays: 7, weekdays: [.mon, .tue, .wed, .thu, .fri]),
                                  busy: [], now: wed)
    let offered = Set(week.map { mtnCal.component(.weekday, from: $0.start) })
    check(offered == [2, 3, 4, 5, 6], "only the listed weekdays are offered")
    check(!offered.contains(1) && !offered.contains(7), "the weekend is not offered")
}

// Lunch.
do {
    let p = reqPolicy(slotMinutes: 30, align: 30, lunch: .init(from: "12:00", to: "13:30"), weekdays: [.wed])
    let got = Set(SlotDeriver.derive(policy: p, busy: [], now: wed).map(\.start))
    check(!got.contains(where: { $0 >= mtn(2026, 9, 2, 12) && $0 < mtn(2026, 9, 2, 13, 30) }),
          "nothing is offered inside lunch")
    check(got.contains(mtn(2026, 9, 2, 11, 30)), "the slot ending as lunch begins survives")
    check(got.contains(mtn(2026, 9, 2, 13, 30)), "and the one starting as it ends")
}

// All-day events. EventKit is inconsistent about whether one ends at 23:59:59 or
// at the following midnight, so both spellings must block the same single day.
do {
    let p = reqPolicy(horizonDays: 3, weekdays: [.wed, .thu, .fri])
    func daysOffered(_ busy: [BusyInterval]) -> Set<Int> {
        Set(SlotDeriver.derive(policy: p, busy: busy, now: wed).map { mtnCal.component(.day, from: $0.start) })
    }
    check(daysOffered([BusyInterval(start: mtn(2026, 9, 3), end: mtn(2026, 9, 4), isAllDay: true)]) == [2, 4],
          "an all-day event blocks its whole day and only its day")
    check(daysOffered([BusyInterval(start: mtn(2026, 9, 3), end: mtn(2026, 9, 3, 23, 59), isAllDay: true)]) == [2, 4],
          "an all-day event that ends at 23:59 blocks the same one day")
    check(daysOffered([BusyInterval(start: mtn(2026, 9, 3, 2), end: mtn(2026, 9, 3, 3))]) == [2, 3, 4],
          "the same span NOT marked all-day only blocks the hours it covers")
}

// Derivation walks the clamped horizon, not the number it was handed.
check(SlotDeriver.derive(policy: reqPolicy(horizonDays: 400, maxPerDay: 1), busy: [], now: wed).count == 45,
      "derivation walks exactly the clamped horizon")

print("SlotDeriver — DST:")
// The whole module exists to pass these. On 8 March 2026 Denver's clocks jump
// 2am → 3am and the local day is 23 hours; on 1 November they fall back and it is
// 25. Deriving by adding 86400 to a UTC instant shifts every slot after the
// change by an hour — silently, plausibly, and only for the people reading the
// page. Each check below states the UTC instant the correct local time maps to.
do {
    let spring = SlotDeriver.derive(policy: reqPolicy(horizonDays: 4), busy: [], now: mtn(2026, 3, 6))
    check(spring.count == 32, "four days of eight slots survive the spring-forward week")
    check(spring.allSatisfy { (9...16).contains(mtnCal.component(.hour, from: $0.start)) },
          "every slot lands inside 9–5 local, on both sides of the change")
    check(localHours(onDay(spring, 3, 8)) == [9, 10, 11, 12, 13, 14, 15, 16],
          "the 23-hour day itself is a full, ordinary working day")
    check(iso(onDay(spring, 3, 7).first!.start) == "2026-03-07T16:00:00Z", "7 March: 9am MST is 16:00Z")
    check(iso(onDay(spring, 3, 8).first!.start) == "2026-03-08T15:00:00Z", "8 March: 9am MDT is 15:00Z")
    check(iso(onDay(spring, 3, 9).first!.start) == "2026-03-09T15:00:00Z", "9 March: the day after is unshifted")
    check(onDay(spring, 3, 8).first!.start.timeIntervalSince(onDay(spring, 3, 7).first!.start) == 82_800,
          "9am to 9am across the jump is 23 hours — a naive +86400 would offer 10am")
}
do {
    let fall = SlotDeriver.derive(policy: reqPolicy(horizonDays: 4), busy: [], now: mtn(2026, 10, 30))
    check(fall.count == 32, "four days of eight slots survive the fall-back week")
    check(fall.allSatisfy { (9...16).contains(mtnCal.component(.hour, from: $0.start)) },
          "every slot lands inside 9–5 local, on both sides of the change")
    check(localHours(onDay(fall, 11, 1)) == [9, 10, 11, 12, 13, 14, 15, 16],
          "the 25-hour day itself is a full, ordinary working day")
    check(iso(onDay(fall, 10, 31).first!.start) == "2026-10-31T15:00:00Z", "31 October: 9am MDT is 15:00Z")
    check(iso(onDay(fall, 11, 1).first!.start) == "2026-11-01T16:00:00Z", "1 November: 9am MST is 16:00Z")
    check(iso(onDay(fall, 11, 2).first!.start) == "2026-11-02T16:00:00Z", "2 November: the day after is unshifted")
    check(onDay(fall, 11, 1).first!.start.timeIntervalSince(onDay(fall, 10, 31).first!.start) == 90_000,
          "9am to 9am across the fall back is 25 hours — a naive +86400 would offer 8am")
}
// A busy event stated in UTC still lands on the local day it belongs to.
do {
    let p = reqPolicy(horizonDays: 4, weekdays: [.sun])
    let busy = [BusyInterval(start: utcISO.date(from: "2026-11-01T17:00:00Z")!,
                             end: utcISO.date(from: "2026-11-01T19:00:00Z")!)]
    check(localHours(SlotDeriver.derive(policy: p, busy: busy, now: mtn(2026, 10, 30))) == [9, 12, 13, 14, 15, 16],
          "17:00–19:00Z on the fall-back day removes 10am and 11am local, and nothing either side")
}

print("PolicyDump:")
// The schema forbids extra properties on purpose: the dump is the only artifact
// that leaves the device, so a field added here in passing is a disclosure. These
// checks mirror askwhen/schema/policy-dump.schema.json key for key.
do {
    let slots = SlotDeriver.derive(policy: reqPolicy(maxPerDay: 3, weekdays: [.wed]), busy: [], now: wed)
    let dump = PolicyDump(slug: "x7f2k9",
                          generated: mtn(2026, 9, 1, 9), expires: mtn(2026, 9, 2, 9),
                          display: .init(name: "Matt Baylor", blurb: "30 minutes.", tz: "America/Denver"),
                          meeting: .init(minutes: 60, title: "Intro call"),
                          slots: slots)
    let data = try dump.encoded()
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    check(Set(obj.keys) == ["v", "slug", "generated", "expires", "display", "meeting", "slots"],
          "the dump has exactly the seven keys the schema allows, and no eighth")
    check(obj["v"] as? Int == 1, "v is the constant 1")
    check(Set((obj["display"] as! [String: Any]).keys) == ["name", "blurb", "tz"],
          "display carries a name, a blurb and a zone — nothing that identifies a calendar")
    check(Set((obj["meeting"] as! [String: Any]).keys) == ["minutes", "title"],
          "a nil location is omitted rather than written")
    let slotObjs = obj["slots"] as! [[String: Any]]
    check(slotObjs.allSatisfy { Set($0.keys) == ["s", "e"] }, "every slot is exactly {s, e}")
    check(slotObjs.allSatisfy { ($0["s"] as? String)?.hasSuffix("Z") == true }, "slot times are Z-terminated UTC")
    check(slotObjs.first?["s"] as? String == "2026-09-02T15:00:00Z", "the first slot is 9am Denver, published as UTC")
    check(obj["generated"] as? String == "2026-09-01T15:00:00Z", "generated is ISO-8601 UTC too")
    check(dump.isSchemaValid, "the dump satisfies the schema's patterns and ranges")
    check(try JSONDecoder().decode(PolicyDump.self, from: data) == dump, "the dump round-trips through encode/decode")

    // Dates are formatted by the type, not by whoever configured the encoder —
    // the page reading this has never heard of a DateEncodingStrategy.
    check(String(data: try JSONEncoder().encode(dump), encoding: .utf8)!.contains("2026-09-02T15:00:00Z"),
          "an unconfigured encoder still produces ISO-8601, not a unix timestamp")

    // Caught on the device, so the owner hears about it rather than the page
    // quietly going dark when the service rejects the write.
    var bad = dump; bad.slug = "NOPE"
    check(bad.validationProblems.contains { $0.contains("slug") }, "a slug that breaks the pattern is caught before publishing")
    bad = dump; bad.display.name = ""
    check(!bad.isSchemaValid, "an empty display name is invalid — the page always shows a label")
    bad = dump; bad.meeting.minutes = 1
    check(!bad.isSchemaValid, "a meeting shorter than five minutes is out of range")

    let many = (0..<600).map { Slot(start: wed.addingTimeInterval(Double($0) * 3600),
                                    end: wed.addingTimeInterval(Double($0) * 3600 + 1800)) }
    check(PolicyDump(slug: "x7f2k9", generated: wed, expires: wed,
                     display: dump.display, meeting: dump.meeting, slots: many).slots.count == 500,
          "slots truncate to the schema's ceiling rather than publishing an invalid document")
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
