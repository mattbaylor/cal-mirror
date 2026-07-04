import Foundation

/// Pure logic for the reverse-direction guard, split out from `MirrorEngine` so
/// it can be unit-tested without EventKit. A mirror A→B combined with B→A would
/// copy each other's copies forever, so both sides are refused.
public enum ReverseDetector {
    public struct Pair: Sendable, Equatable {
        public let id: String
        public let source: String   // resolved calendar identifier
        public let dest: String
        public init(id: String, source: String, dest: String) {
            self.id = id; self.source = source; self.dest = dest
        }
    }

    /// Ids that form an A→B / B→A reverse pair — every id on either side.
    public static func reversedIds(_ pairs: [Pair]) -> Set<String> {
        var reversed = Set<String>()
        for a in pairs {
            for b in pairs where b.id != a.id {
                if b.source == a.dest && b.dest == a.source {
                    reversed.insert(a.id); reversed.insert(b.id)
                }
            }
        }
        return reversed
    }
}
