import Foundation
import CryptoKit

extension PolicyDump {

    /// Build the dump from the owner's page config and what the calendar says.
    ///
    /// This is the one publish site, and the place two facts the design flags
    /// are pinned together: `meeting.minutes` is `policy.slotMinutes` — the same
    /// number, written once — and `display.tz` is `policy.timeZone`, the zone
    /// the rules were written in. Neither can be set to disagree from here.
    ///
    /// `expires` is 24 hours out, matching the service's own ceiling. A device
    /// that stops publishing takes its page down in a day, which is the point.
    public static func make(from page: RequestPageConfig, busy: [BusyInterval], now: Date) -> PolicyDump {
        let slots = SlotDeriver.derive(policy: page.policy, busy: busy, now: now)
        return PolicyDump(
            slug: page.slug,
            generated: now,
            expires: now.addingTimeInterval(24 * 3600),
            display: Display(name: page.displayName, blurb: page.blurb, tz: page.policy.timeZone),
            meeting: Meeting(minutes: page.policy.slotMinutes, title: page.meetingTitle,
                             location: page.meetingLocation),
            slots: slots)
    }

    /// A hash of what the dump *says*, ignoring when it was said.
    ///
    /// `generated` and `expires` change on every derivation, so the bytes on the
    /// wire never repeat and the service's strong ETag (SHA-256 of those bytes)
    /// cannot tell "same offers" from "new offers". This can: it hashes the
    /// document with both timestamps pinned, so two derivations that offer the
    /// same times have the same fingerprint and the second is not uploaded.
    public func contentFingerprint() -> String {
        var pinned = self
        pinned.generated = Date(timeIntervalSince1970: 0)
        pinned.expires = Date(timeIntervalSince1970: 0)
        // encoded() sorts keys, so this is stable across runs and platforms.
        let bytes = (try? pinned.encoded()) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Decides whether a sync cycle should PUT the dump it just derived.
///
/// Two reasons to publish, and only two: the offers changed, or the last upload
/// is old enough that the service is about to expire it. Everything else — the
/// cycle ran, the calendar moved somewhere that did not affect the offers, a
/// timestamp ticked — is not a reason, and treating it as one would mean a PUT
/// every few minutes from every device for no change anyone could see.
public enum PublishPlanner {

    /// Republish this long after the last upload even when nothing changed.
    /// Half the service's 24-hour dump TTL: one missed cycle does not take the
    /// page down, two do — which is the correct behaviour for a device that has
    /// actually gone quiet.
    public static let refreshAfter: TimeInterval = 12 * 3600

    public enum Decision: Equatable, Sendable {
        case publish(reason: Reason)
        case skip
    }

    public enum Reason: String, Sendable {
        case firstPublish, offersChanged, refresh
    }

    public static func decide(fingerprint: String, lastFingerprint: String?, lastPublishedAt: Date?,
                              now: Date, refreshAfter: TimeInterval = refreshAfter) -> Decision {
        guard let last = lastFingerprint, let at = lastPublishedAt else {
            return .publish(reason: .firstPublish)
        }
        if last != fingerprint { return .publish(reason: .offersChanged) }
        if now.timeIntervalSince(at) >= refreshAfter { return .publish(reason: .refresh) }
        return .skip
    }
}

/// The re-check at the moment of truth (architecture §6).
///
/// The dump was a snapshot; the calendar is the truth. Between publish and
/// accept, something may have landed on the requested time, and the owner must
/// be told before an event is written over it — not after, and not never, which
/// is what a hosted service that believes its own copy would do.
public enum RequestChecker {

    public enum Verdict: Equatable, Sendable {
        /// Nothing in the blocking calendars overlaps the slot, buffer included.
        case clear
        /// Something does. `alternatives` are the nearest offers that are still
        /// open now, so the owner can propose one instead of just saying no.
        case conflict(alternatives: [Slot])
    }

    /// `busy` is what the blocking calendars hold *now*. The policy supplies the
    /// buffer and, for alternatives, the rules to re-derive under.
    ///
    /// This deliberately does not ask "would the deriver still offer it?" —
    /// the per-day cap and minimum notice can both exclude a slot that is in
    /// fact free, and an owner accepting a time inside their own notice window
    /// is a choice, not a conflict.
    public static func check(slot: Slot, policy: RequestPolicy, busy: [BusyInterval],
                             now: Date, alternatives: Int = 3) -> Verdict {
        let buffer = TimeInterval(policy.bufferMinutes) * 60
        let from = slot.start.addingTimeInterval(-buffer)
        let to = slot.end.addingTimeInterval(buffer)

        // Timed events overlap the buffered span. All-day events block the local
        // day the slot starts in, half-open, exactly as the deriver counts them.
        let clashes = busy.contains { b in
            if b.isAllDay {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: policy.timeZone) ?? .current
                let day = cal.startOfDay(for: slot.start)
                let next = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
                return b.start < next && b.end > day
            }
            return from < b.end && to > b.start
        }
        if !clashes { return .clear }

        let open = SlotDeriver.derive(policy: policy, busy: busy, now: now)
            .filter { $0 != slot }
            .sorted { abs($0.start.timeIntervalSince(slot.start)) < abs($1.start.timeIntervalSince(slot.start)) }
        return .conflict(alternatives: Array(open.prefix(alternatives)))
    }
}
