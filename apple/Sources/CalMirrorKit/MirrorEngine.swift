import Foundation
import EventKit

/// A calendar available on this device, for pickers and matching.
public struct CalendarInfo: Identifiable, Hashable, Sendable {
    public let title: String
    public let account: String
    public let identifier: String
    public let writable: Bool
    public var id: String { identifier }
    public var label: String { "\(title) — \(account)" }
}

/// The result of syncing one mirror.
public struct MirrorResult: Identifiable, Sendable {
    public let id: String
    public let name: String
    public var ok: Bool
    public var error: String?
    public var created = 0, updated = 0, unchanged = 0, deleted = 0
    public var total: Int { created + updated + unchanged }
}

/// Cross-platform EventKit sync engine. Identical on macOS and iOS/iPadOS —
/// only scheduling and UI differ per platform.
/// `@unchecked Sendable`: the store and `lastOwned` are touched only during a
/// sync, and callers serialize syncs (the Store's `!syncing` guard), so the one
/// long-lived engine can be handed to a background task safely.
public final class MirrorEngine: @unchecked Sendable {
    private let store = EKEventStore()
    /// Owned-copy count from each mirror's last successful sync, used by
    /// `SnapshotGuard` to veto reconciling against a collapsed/stale view.
    /// Meaningful only on a long-lived engine (reuse one instance across syncs).
    private var lastOwned: [String: Int] = [:]
    public init() {}

    // MARK: Access

    public func requestAccess() async -> Bool {
        do { return try await store.requestFullAccessToEvents() } catch { return false }
    }

    /// Ask EventKit to pull the local CalDAV cache up to date. Cheap and async on
    /// the daemon side; the per-mirror stability check below is what actually waits
    /// for the snapshot to settle before we reconcile.
    public func refreshSources() { store.refreshSourcesIfNecessary() }

    /// Diagnostic: totals + duplicate-group count for a destination, read through
    /// the engine's OWN store (the authoritative one in production).
    public func debugStats(title: String, pastDays: Double = 400, futureDays: Double = 400)
        -> (total: Int, unique: Int, dupGroups: Int) {
        guard let cal = store.calendars(for: .event).first(where: { $0.title == title }) else { return (-1, -1, -1) }
        let now = Date()
        let evs = store.events(matching: store.predicateForEvents(
            withStart: now.addingTimeInterval(-pastDays * 86400),
            end: now.addingTimeInterval(futureDays * 86400), calendars: [cal]))
        var fp: [String: Int] = [:]
        for e in evs where (e.url?.scheme ?? "").hasPrefix("x-calmirror") && !(e.url?.scheme ?? "").contains("status") {
            fp[fingerprint(e, now: now), default: 0] += 1
        }
        return (evs.count, fp.count, fp.filter { $0.value > 1 }.count)
    }

    public func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map {
            CalendarInfo(title: $0.title, account: $0.source.title,
                         identifier: $0.calendarIdentifier, writable: $0.allowsContentModifications)
        }.sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    // MARK: Sync

    /// Sync every enabled mirror in `config`. `log` receives progress lines.
    @discardableResult
    public func syncAll(_ config: Config, now: Date = Date(),
                        log: ((String) -> Void)? = nil) -> [MirrorResult] {
        let reversed = reversedMirrorIds(in: config)
        return config.mirrors.map { m in
            if !m.enabled { return MirrorResult(id: m.id, name: m.name, ok: true, error: "disabled") }
            if reversed.contains(m.id) {
                log?("[\(m.id)] REFUSED: reverse of another mirror — would create a copy loop")
                return MirrorResult(id: m.id, name: m.name, ok: false,
                                    error: "Reverse of another mirror — refused to avoid a loop")
            }
            return syncMirror(m, allMirrors: config.mirrors, now: now, log: log)
        }
    }

    /// Mirror ids that form an A->B / B->A reverse pair — both sides are refused.
    /// Resolves each mirror to calendar identifiers, then defers to the pure
    /// `ReverseDetector` (unit-tested without EventKit).
    private func reversedMirrorIds(in config: Config) -> Set<String> {
        let pairs: [ReverseDetector.Pair] = config.mirrors.filter { $0.enabled }.compactMap { m in
            guard let s = findCalendar(m.source)?.calendarIdentifier,
                  let d = findCalendar(m.dest)?.calendarIdentifier else { return nil }
            return ReverseDetector.Pair(id: m.id, source: s, dest: d)
        }
        return ReverseDetector.reversedIds(pairs)
    }

    /// For the UI: would a (source -> dest) mirror reverse an existing one?
    /// Returns the conflicting mirror if so.
    public func reverseConflict(source: CalRef, dest: CalRef,
                                in mirrors: [Mirror], excluding id: String? = nil) -> Mirror? {
        guard let s = findCalendar(source)?.calendarIdentifier,
              let d = findCalendar(dest)?.calendarIdentifier else { return nil }
        return mirrors.first { m in
            m.id != id
                && findCalendar(m.source)?.calendarIdentifier == d
                && findCalendar(m.dest)?.calendarIdentifier == s
        }
    }

    /// Remove ALL mirror-tagged events from every configured destination.
    @discardableResult
    public func purge(_ config: Config, now: Date = Date()) -> Int {
        let wide = 800.0 * 86400
        var removed = 0
        for m in config.mirrors {
            guard let dest = findCalendar(m.dest) else { continue }
            let evs = store.events(matching: store.predicateForEvents(
                withStart: now.addingTimeInterval(-wide), end: now.addingTimeInterval(wide), calendars: [dest]))
            for ev in evs where Markers.isMirrorTag(ev.url) {
                try? store.remove(ev, span: .thisEvent, commit: false); removed += 1
            }
        }
        try? store.commit()
        return removed
    }

    // MARK: - Internals

    private func findCalendar(_ ref: CalRef) -> EKCalendar? {
        let all = store.calendars(for: .event)
        if let acct = ref.account,
           let c = all.first(where: { $0.title == ref.title && $0.source.title == acct }) { return c }
        return all.first { $0.title == ref.title }
    }

    private func keyFor(_ ev: EKEvent, now: Date) -> String {
        let start = Int((ev.startDate ?? now).timeIntervalSince1970)
        // Prefer the stable external identifier. Subscribed/feed calendars often
        // expose no external id (and an unstable eventIdentifier); the old fallback
        // to a random UUID re-keyed those events on every fetch. Fall back to a
        // deterministic content hash instead.
        let base: String
        if let ext = ev.calendarItemExternalIdentifier, !ext.isEmpty {
            base = ext
        } else {
            let end = Int((ev.endDate ?? ev.startDate ?? now).timeIntervalSince1970)
            base = "c:\(ev.title ?? "")#\(end)#\(ev.isAllDay ? 1 : 0)#\(ev.location ?? "")"
        }
        return Data("\(base)#\(start)".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Content signature used as the *fuzzy* dedup axis: two events that match on
    /// title + start + end + all-day are treated as the same event even if their
    /// marker keys diverge. The title MUST be the *projected* title (what the copy
    /// actually contains) so a redacted copy still fuzzy-matches its source.
    private func fingerprintOf(title: String, start: Date?, end: Date?, allDay: Bool, now: Date) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = Int((start ?? now).timeIntervalSince1970)
        let e = Int((end ?? now).timeIntervalSince1970)
        return "\(t)|\(s)|\(e)|\(allDay)"
    }
    private func fingerprint(_ ev: EKEvent, now: Date) -> String {
        fingerprintOf(title: ev.title ?? "", start: ev.startDate, end: ev.endDate, allDay: ev.isAllDay, now: now)
    }

    // MARK: Projection

    private struct Snap { var title: String; var location: String?; var notes: String?
                          var availability: EKEventAvailability; var alarmSig: String; var copyAlarms: Bool }

    /// The single source of truth for what a copy should contain, given the
    /// mirror's projection and any per-event override tag on the source title.
    private func snapshot(_ src: EKEvent, mirror m: Mirror) -> Snap {
        let tags = scanTags(src.title ?? "")
        let p = m.projection
        let redact: Bool, loc: Bool, notes: Bool, alarms: Bool, busy: Bool
        if tags.forcePrivate {          // #private wins: nothing but a block
            redact = true; loc = false; notes = false; alarms = false; busy = true
        } else if tags.forcePublic {    // #public: replicate content, availability from source
            redact = false; loc = true; notes = true; alarms = p.alarms; busy = false
        } else {
            redact = (p.title == .redact); loc = p.location; notes = p.notes
            alarms = p.alarms; busy = (p.availability == .busy)
        }
        let title = redact ? (p.titleText.isEmpty ? "Busy" : p.titleText)
                           : (tags.clean.isEmpty ? "(no title)" : tags.clean)
        // Subscribed feeds report .notSupported, which the destination coerces to
        // .busy on write, so comparing against it would flag a diff every run.
        let resolved: EKEventAvailability = busy ? .busy : src.availability
        let avail: EKEventAvailability = (resolved == .notSupported) ? .busy : resolved
        return Snap(title: title, location: loc ? src.location : nil, notes: notes ? src.notes : nil,
                    availability: avail, alarmSig: alarms ? alarmSig(src.alarms) : "", copyAlarms: alarms)
    }

    /// Order-independent fingerprint of an alarm set, so differ() can tell whether
    /// the copy's alarms already match without re-saving every run.
    private func alarmSig(_ alarms: [EKAlarm]?) -> String {
        guard let a = alarms, !a.isEmpty else { return "" }
        return a.map { $0.absoluteDate.map { "@\(Int($0.timeIntervalSince1970))" } ?? "r\(Int($0.relativeOffset))" }
            .sorted().joined(separator: ",")
    }
    private func cloneAlarm(_ a: EKAlarm) -> EKAlarm {
        if let d = a.absoluteDate { return EKAlarm(absoluteDate: d) }
        return EKAlarm(relativeOffset: a.relativeOffset)
    }

    /// True if `ev` is itself a cal-mirror artifact — a copy some mirror wrote, or
    /// a heartbeat banner — so it's skipped as a source (no copy-of-a-copy).
    private func isMirrorArtifact(_ ev: EKEvent, mirrors: [Mirror]) -> Bool {
        guard let sc = ev.url?.scheme else { return false }
        if sc.hasPrefix(Markers.scheme) { return true }              // x-calmirror marker + status
        if Markers.owner(of: ev.url, mirrors: mirrors) != nil { return true }
        return mirrors.contains { ($0.legacyScheme.map { $0 + "-status" }) == sc }
    }

    private func syncMirror(_ m: Mirror, allMirrors: [Mirror], now: Date,
                            log: ((String) -> Void)?) -> MirrorResult {
        var r = MirrorResult(id: m.id, name: m.name, ok: true)
        guard let source = findCalendar(m.source) else {
            r.ok = false; r.error = "Source not found"; return r
        }
        guard let dest = findCalendar(m.dest) else {
            r.ok = false; r.error = "Destination not found"; return r
        }
        if source.calendarIdentifier == dest.calendarIdentifier {
            r.ok = false; r.error = "Source and destination are the same"; return r
        }
        guard dest.allowsContentModifications else {
            r.ok = false; r.error = "Destination is read-only"; return r
        }

        let winStart = now.addingTimeInterval(-m.windowPastDays * 86400)
        let winEnd = now.addingTimeInterval(m.windowFutureDays * 86400)

        // --- Stale-snapshot protection ---------------------------------------
        // A fresh EKEventStore serves a partial CalDAV snapshot until it settles.
        // Refresh, then wait until the destination's owned-copy count is stable
        // across reads; SnapshotGuard then vetoes acting on an unsettled or
        // collapsed view (which is what created/kept duplicates). Runs on a
        // background queue, so the brief blocking waits are fine.
        store.refreshSourcesIfNecessary()
        func ownedCount() -> Int {
            store.events(matching: store.predicateForEvents(
                withStart: winStart.addingTimeInterval(-86400),
                end: winEnd.addingTimeInterval(86400), calendars: [dest]))
                .reduce(0) { Markers.owner(of: $1.url, mirrors: allMirrors)?.id == m.id ? $0 + 1 : $0 }
        }
        var prev = -1, stableReads = 0, waited = 0.0
        let pollStep = 1.5, pollMax = 12.0
        while stableReads < 2 && waited <= pollMax {
            let c = ownedCount()
            if c == prev { stableReads += 1 } else { stableReads = 0; prev = c }
            if stableReads < 2 { Thread.sleep(forTimeInterval: pollStep); waited += pollStep }
        }
        if case let .skip(why) = SnapshotGuard.decide(
            stabilized: stableReads >= 2, count: prev, lastKnown: lastOwned[m.id]) {
            r.ok = true; r.error = "deferred: \(why)"
            log?("[\(m.id)] DEFER — \(why)")
            return r
        }

        let srcEvents = store.events(matching:
            store.predicateForEvents(withStart: winStart, end: winEnd, calendars: [source]))
        var srcList: [EKEvent] = []
        var snaps: [Snap] = []                 // parallel to srcList; built once per event
        var desiredList: [Reconciler.Desired] = []
        for ev in srcEvents {
            if isMirrorArtifact(ev, mirrors: allMirrors) { continue }   // don't re-mirror a copy/heartbeat
            if scanTags(ev.title ?? "").skip { continue }               // honor #nomirror
            let snap = snapshot(ev, mirror: m)
            srcList.append(ev)
            snaps.append(snap)
            // Fingerprint uses the PROJECTED title so a redacted copy still
            // fuzzy-matches its source (the copy carries the projected title).
            desiredList.append(.init(
                key: keyFor(ev, now: now),
                fingerprint: fingerprintOf(title: snap.title, start: ev.startDate,
                                           end: ev.endDate, allDay: ev.isAllDay, now: now)))
        }

        let dstEvents = store.events(matching: store.predicateForEvents(
            withStart: winStart.addingTimeInterval(-86400),
            end: winEnd.addingTimeInterval(86400), calendars: [dest]))
        // Collect every mirror-owned copy (NOT a dictionary — duplicate keys must
        // survive so the reconciler can collapse them). Heartbeat handled apart.
        var ownedEvents: [EKEvent] = []
        var ownedRaw: [(key: String, fp: String, id: String)] = []
        var heartbeat: EKEvent?
        let legacyHB = m.legacyScheme.map { $0 + "-status" }
        for ev in dstEvents {
            if let sc = ev.url?.scheme, sc == Markers.heartbeatScheme || sc == legacyHB {
                let opaque = ev.url!.absoluteString.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                if sc == legacyHB || opaque == m.id { heartbeat = ev }
                continue
            }
            if let owner = Markers.owner(of: ev.url, mirrors: allMirrors), owner.id == m.id {
                ownedEvents.append(ev)
                ownedRaw.append((owner.key, fingerprint(ev, now: now), ev.calendarItemIdentifier))
            }
        }
        // Sort owned copies by a durable id so the reconciler's survivor pick
        // (lowest ref) is stable across runs; `ref` indexes `owned`.
        let sortedIdx = ownedEvents.indices.sorted { ownedRaw[$0].id < ownedRaw[$1].id }
        var owned: [EKEvent] = []
        var existingList: [Reconciler.Existing] = []
        for (ref, old) in sortedIdx.enumerated() {
            owned.append(ownedEvents[old])
            existingList.append(.init(ref: ref, key: ownedRaw[old].key, fingerprint: ownedRaw[old].fp))
        }

        func differ(_ copy: EKEvent, _ src: EKEvent, _ s: Snap, key: String) -> Bool {
            copy.title != s.title || copy.startDate != src.startDate ||
            copy.endDate != src.endDate || copy.isAllDay != src.isAllDay ||
            (copy.location ?? "") != (s.location ?? "") ||
            (copy.notes ?? "") != (s.notes ?? "") ||
            copy.availability != s.availability ||
            alarmSig(copy.alarms) != s.alarmSig ||
            copy.url != Markers.copyURL(mirrorId: m.id, key: key)
        }
        func apply(_ copy: EKEvent, _ src: EKEvent, _ s: Snap, key: String) {
            copy.title = s.title
            copy.startDate = src.startDate; copy.endDate = src.endDate
            copy.isAllDay = src.isAllDay; copy.timeZone = src.timeZone
            copy.location = s.location; copy.notes = s.notes
            copy.availability = s.availability
            copy.alarms?.forEach { copy.removeAlarm($0) }
            if s.copyAlarms, let alarms = src.alarms { for a in alarms { copy.addAlarm(cloneAlarm(a)) } }
            copy.url = Markers.copyURL(mirrorId: m.id, key: key); copy.calendar = dest
        }
        var pending = 0
        func maybeCommit(_ force: Bool = false) {
            if force || pending >= 50 { try? store.commit(); pending = 0 }
        }

        // Pure planner decides create/match/delete and collapses duplicates.
        let plan = Reconciler.plan(desired: desiredList, existing: existingList)
        for (di, ref) in plan.match {
            let copy = owned[ref], src = srcList[di], s = snaps[di], key = desiredList[di].key
            if differ(copy, src, s, key: key) {   // includes url != new key → adopted copies re-stamp here
                apply(copy, src, s, key: key)
                try? store.save(copy, span: .thisEvent, commit: false); pending += 1
                r.updated += 1
            } else { r.unchanged += 1 }
            maybeCommit()
        }
        for di in plan.create {
            let c = EKEvent(eventStore: store); apply(c, srcList[di], snaps[di], key: desiredList[di].key)
            try? store.save(c, span: .thisEvent, commit: false); pending += 1
            r.created += 1
            maybeCommit()
        }
        for ref in plan.delete {             // duplicate twins + stale copies (owned-only, safe)
            try? store.remove(owned[ref], span: .thisEvent, commit: false); pending += 1
            r.deleted += 1
            maybeCommit()
        }
        maybeCommit(true)

        // Heartbeat banner
        if !m.showHeartbeat {
            if let hb = heartbeat { try? store.remove(hb, span: .thisEvent, commit: true) }
        } else {
            let dayStart = Calendar.current.startOfDay(for: now)
            let tf = DateFormatter(); tf.dateFormat = "h:mm a"
            let ev = heartbeat ?? EKEvent(eventStore: store)
            ev.calendar = dest
            ev.isAllDay = true; ev.startDate = dayStart; ev.endDate = dayStart
            ev.title = "🗓️ \(m.name) ✓ \(r.total) events · \(tf.string(from: now))"
            ev.url = Markers.heartbeatURL(mirrorId: m.id)
            try? store.save(ev, span: .thisEvent, commit: true)
        }

        // Trust this cycle's owned-copy count as the baseline the guard compares
        // future (possibly stale) snapshots against.
        lastOwned[m.id] = r.total

        log?("[\(m.id)] +\(r.created) ~\(r.updated) =\(r.unchanged) -\(r.deleted)")
        return r
    }
}
