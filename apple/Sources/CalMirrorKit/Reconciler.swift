import Foundation

/// Pure sync-planning logic, split out of `MirrorEngine` so it can be unit-tested
/// without EventKit. Given the source events we *want* in the destination and the
/// mirror-owned copies already there, it decides what to create, match (update or
/// leave), and delete — always converging to **exactly one destination copy per
/// source event**, which is what makes the mirror idempotent and self-healing.
///
/// Two dedup axes, in priority order:
///   1. **Marker key** — precise identity carried in each copy's `url`. Handles
///      renames/moves and is the primary match. Identical-key collisions (two
///      copies with the same key — the duplicate bug in issue #2) collapse to one.
///   2. **Content fingerprint** — `title + start + end + all-day`. The *fuzzy*
///      fallback: when a source event has no exact key match, an existing copy
///      with the same fingerprint is adopted (re-stamped) instead of creating a
///      second copy. This mops up any duplicate whose key diverged.
///
/// Safety: only mirror-*owned* copies are ever passed in, so the resulting
/// `delete` list can never touch a user's own events on a shared destination.
public enum Reconciler {

    /// A source event we want mirrored.
    public struct Desired: Sendable, Equatable {
        public let key: String          // stable occurrence key (goes in the marker)
        public let fingerprint: String  // title|start|end|allDay
        public init(key: String, fingerprint: String) {
            self.key = key; self.fingerprint = fingerprint
        }
    }

    /// An existing mirror-owned copy in the destination. `ref` is an opaque handle
    /// (e.g. an array index) the caller uses to map back to the real `EKEvent`.
    public struct Existing: Sendable, Equatable {
        public let ref: Int
        public let key: String          // owner key parsed from the marker
        public let fingerprint: String
        public init(ref: Int, key: String, fingerprint: String) {
            self.ref = ref; self.key = key; self.fingerprint = fingerprint
        }
    }

    public struct Plan: Sendable, Equatable {
        /// desired-index → existing `ref` to reuse (caller updates it if content differs).
        public var match: [Int: Int] = [:]
        /// desired-indexes with no reusable copy → create a fresh event.
        public var create: [Int] = []
        /// existing `ref`s to delete (duplicate twins + stale copies whose source is gone).
        public var delete: [Int] = []
    }

    /// Plan the reconciliation. Deterministic: same inputs → same plan (survivors
    /// are chosen by lowest `ref`, so the caller should sort existing copies by a
    /// stable id first).
    public static func plan(desired: [Desired], existing: [Existing]) -> Plan {
        var plan = Plan()
        var consumed = Set<Int>()

        // Index available copies, refs sorted ascending so the survivor is stable.
        var byKey: [String: [Int]] = [:]
        var byFP: [String: [Int]] = [:]
        let byRef = Dictionary(uniqueKeysWithValues: existing.map { ($0.ref, $0) })
        for e in existing.sorted(by: { $0.ref < $1.ref }) {
            byKey[e.key, default: []].append(e.ref)
            byFP[e.fingerprint, default: []].append(e.ref)
        }

        func take(_ refs: [Int]?) -> Int? {
            guard let refs else { return nil }
            return refs.first { !consumed.contains($0) }
        }

        // Process desired in a stable order (by key) for determinism.
        let order = desired.indices.sorted { desired[$0].key < desired[$1].key }

        // Pass A — exact marker-key match. Collapse same-key duplicate twins.
        for i in order {
            guard let ref = take(byKey[desired[i].key]) else { continue }
            consumed.insert(ref)
            plan.match[i] = ref
            // Any other copies sharing this exact key are duplicates → delete.
            for extra in byKey[desired[i].key] ?? [] where !consumed.contains(extra) {
                consumed.insert(extra); plan.delete.append(extra)
            }
        }

        // Pass B — fuzzy fingerprint fallback for still-unmatched desired events.
        for i in order where plan.match[i] == nil {
            guard let ref = take(byFP[desired[i].fingerprint]) else { continue }
            consumed.insert(ref)
            plan.match[i] = ref   // caller re-stamps the marker + updates content
        }

        // Pass C — no reusable copy → create.
        for i in order where plan.match[i] == nil { plan.create.append(i) }

        // Pass D — any owned copy left over is a duplicate or a stale copy → delete.
        for e in existing where !consumed.contains(e.ref) { plan.delete.append(e.ref) }

        plan.delete.sort()
        _ = byRef   // (kept for clarity; refs validated by construction)
        return plan
    }
}
