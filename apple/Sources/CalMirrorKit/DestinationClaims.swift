import Foundation

/// Stops two mirrors writing the same block twice into one destination.
///
/// Point a work calendar and an on-call feed at the same "Work (Copy)" and any
/// shift that appears in both gets copied twice — two identical blocks, stacked,
/// on a calendar you probably share. Each mirror's delete-sweep only touches its
/// own copies, so neither ever cleans the other's up.
///
/// The claim is keyed on the destination and the copy's **fingerprint**, which
/// is built from the *projected* title — what the copy will actually say. That
/// gives the safety property for free: a busy-only mirror produces "Busy" and a
/// full-copy mirror produces "Standup", so they fingerprint differently and both
/// copies survive. Only genuinely identical blocks collapse, and collapsing two
/// indistinguishable "Busy" blocks at the same time is the point rather than a
/// side effect.
///
/// First claim wins, in config order, so the result does not depend on which
/// mirror happened to run first and does not flap between cycles. If the owning
/// mirror is later disabled or deleted, the next mirror claims it on the
/// following cycle and the copy reappears — no repair step needed.
public struct DestinationClaims: Sendable {
    private var taken: Set<String> = []

    public init() {}

    private static func slot(dest: String, fingerprint: String) -> String {
        // \u{1} cannot appear in a calendar identifier or a fingerprint, so the
        // two halves can never run together into a false match.
        "\(dest)\u{1}\(fingerprint)"
    }

    /// Claim this block for a mirror. `true` if the caller should write it,
    /// `false` if an earlier mirror already owns an identical one here.
    public mutating func claim(dest: String, fingerprint: String) -> Bool {
        taken.insert(Self.slot(dest: dest, fingerprint: fingerprint)).inserted
    }

    /// Whether a block is already spoken for, without taking it.
    public func isClaimed(dest: String, fingerprint: String) -> Bool {
        taken.contains(Self.slot(dest: dest, fingerprint: fingerprint))
    }

    public var count: Int { taken.count }
}
