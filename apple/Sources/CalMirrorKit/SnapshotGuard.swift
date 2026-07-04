import Foundation

/// Pure decision logic for whether a destination snapshot is trustworthy enough
/// to reconcile against. Split out of `MirrorEngine` so it can be unit-tested
/// without EventKit.
///
/// Why this exists: a freshly-made `EKEventStore` serves a **stale/partial
/// snapshot** of a CalDAV calendar until it refreshes. Reconciling against that
/// phantom view is what created duplicate storms (store missing existing copies →
/// recreate them) and blocked healing (store missing the dupes). We only act when
/// the view has **stabilized** (equal reads) and hasn't **collapsed** versus the
/// last count we trusted.
public enum SnapshotGuard {
    public enum Decision: Equatable {
        case proceed
        case skip(String)   // reason (for logging); defer this cycle
    }

    /// - Parameters:
    ///   - stabilized: did repeated reads of the destination agree (view settled)?
    ///   - count: the stabilized owned-copy count.
    ///   - lastKnown: owned-copy count from the last successful sync (nil = first run).
    public static func decide(stabilized: Bool, count: Int, lastKnown: Int?) -> Decision {
        if !stabilized {
            return .skip("destination view never settled")
        }
        // A view that collapsed to a small fraction of what we last trusted is
        // almost certainly a cold/partial snapshot — never mass-create against it.
        if let last = lastKnown, last > 4, count * 4 < last {
            return .skip("view collapsed (\(count) vs last \(last)) — likely stale")
        }
        return .proceed
    }
}
