import Foundation

/// Decides *when* to run a sync cycle, so the daemon can stop sleeping a fixed
/// interval and start reacting to calendar changes.
///
/// EventKit posts `.EKEventStoreChanged` when the local store changes — your own
/// edits, and remote changes once a CalDAV/Exchange pull lands. Reacting to that
/// naively goes wrong in three ways, and this type is the three answers:
///
///  1. **Bursts.** One CalDAV pull can deliver hundreds of events as a stream of
///     notifications. Debounce collapses them into a single sync, with a cap so a
///     long slow drip can't defer the sync forever.
///  2. **Our own writes.** Every write to a destination posts the same
///     notification, so a sync could trigger the next one. `HeartbeatPolicy`
///     removed the *periodic* write that would have made this a true loop; the
///     suppression window here handles the rest.
///  3. **Cost.** A cycle is not free — each mirror waits for its destination
///     snapshot to settle — so a minimum gap bounds how often change can drive
///     one.
///
/// The scheduled interval never goes away. `EKEventStoreChanged` is best-effort,
/// subscribed ICS feeds refresh on their own schedule without announcing it, and
/// sleep drops notifications outright. The floor is a correctness backstop, not a
/// preference: without it a missed notification means a mirror that is silently
/// stale forever, and nothing in the system would ever notice.
///
/// Unlike `Reconciler` and `SnapshotGuard` this one carries state, because the
/// question it answers is inherently about history — what happened, and when.
/// It stays a plain value with no I/O and no clock of its own: every method takes
/// the time as a parameter, so `cmk-check` drives it through hours of scenarios
/// instantly and deterministically.
public struct SyncScheduler: Equatable, Sendable {

    public struct Tuning: Equatable, Sendable {
        /// Quiet period after the last change before syncing.
        public var debounce: TimeInterval
        /// Longest we'll defer once changes start arriving, however they keep coming.
        public var maxDebounce: TimeInterval
        /// Floor on the spacing between change-driven syncs.
        public var minGap: TimeInterval
        /// Changes seen within this long after our own write are assumed to be
        /// that write echoing back, and ignored.
        public var selfWriteWindow: TimeInterval

        public init(debounce: TimeInterval = 10, maxDebounce: TimeInterval = 60,
                    minGap: TimeInterval = 60, selfWriteWindow: TimeInterval = 5) {
            self.debounce = debounce; self.maxDebounce = maxDebounce
            self.minGap = minGap; self.selfWriteWindow = selfWriteWindow
        }
    }

    /// Why a cycle fired. Carried into the log and `status.json`: without it a
    /// healthy change-driven system and one thrashing on its own writes produce
    /// identical output, and you'd have no way to tell them apart.
    public enum Reason: String, Equatable, Sendable {
        case first      // nothing has run yet this process
        case change     // a calendar change, debounced
        case floor      // the scheduled backstop
    }

    public enum Decision: Equatable, Sendable {
        case sync(Reason)
        case wait(TimeInterval)
    }

    public var tuning: Tuning

    /// When the last cycle *finished*. Measuring from completion rather than
    /// start is what stops a slow cycle from immediately queueing the next.
    public private(set) var lastSyncAt: Date?
    public private(set) var lastWriteAt: Date?
    public private(set) var changeFirstSeenAt: Date?
    public private(set) var changeLastSeenAt: Date?

    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    // MARK: Events in

    /// Record a store change. Returns whether it was accepted — a change inside
    /// the self-write window is our own echo and is dropped.
    ///
    /// This does mean a genuine external edit landing while we're mid-sync gets
    /// swallowed. That's the deliberate trade: the floor catches it within the
    /// interval, and the alternative is a system that can chase its own tail.
    @discardableResult
    public mutating func noteChange(at when: Date) -> Bool {
        if let w = lastWriteAt, when.timeIntervalSince(w) < tuning.selfWriteWindow { return false }
        if changeFirstSeenAt == nil { changeFirstSeenAt = when }
        changeLastSeenAt = when
        return true
    }

    /// Record that we committed to a store — starts the self-write window.
    public mutating func noteWrite(at when: Date) { lastWriteAt = when }

    /// Record that a cycle finished. Clears the pending burst: whatever those
    /// changes were, the cycle that just ran has seen them.
    public mutating func noteSyncFinished(at when: Date) {
        lastSyncAt = when
        changeFirstSeenAt = nil
        changeLastSeenAt = nil
    }

    // MARK: The decision

    /// - Parameter intervalSeconds: the floor from config — "sync at least this
    ///   often". Clamped the same way the daemon clamps it, so a nonsense value
    ///   can't produce a hot loop.
    public func decide(now: Date, intervalSeconds: Int) -> Decision {
        let interval = TimeInterval(max(60, intervalSeconds))

        // Nothing has run yet: run.
        guard let lastSync = lastSyncAt else { return .sync(.first) }

        let sinceSync = now.timeIntervalSince(lastSync)

        // The floor answers to nothing else. It exists precisely for the case
        // where change detection has failed, so gating it on minGap would let a
        // misbehaving notification stream suppress the backstop protecting
        // against that same stream.
        if sinceSync >= interval { return .sync(.floor) }

        var waits: [TimeInterval] = [interval - sinceSync]

        if let first = changeFirstSeenAt, let last = changeLastSeenAt {
            let quietFor = now.timeIntervalSince(last)
            let pendingFor = now.timeIntervalSince(first)
            let settled = quietFor >= tuning.debounce || pendingFor >= tuning.maxDebounce

            if settled {
                // Ready, but a change-driven cycle still respects the gap.
                if sinceSync >= tuning.minGap { return .sync(.change) }
                waits.append(tuning.minGap - sinceSync)
            } else {
                waits.append(tuning.debounce - quietFor)
                waits.append(tuning.maxDebounce - pendingFor)
            }
        }

        // Wake for whichever deadline comes first, never busy-loop.
        return .wait(max(0.5, waits.min() ?? interval))
    }
}
