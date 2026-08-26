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
    check(p.title == .copy && p.location && !p.notes && !p.alarms && p.availability == .source,
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
    check(p.title == .redact && p.titleText == "Out" && !p.location && p.notes
          && p.availability == .busy && p.custom, "projection fields decode")
    check(p.alarms == false, "malformed field falls back to default (no throw)")
}
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
