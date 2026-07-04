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

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
