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
    /// A real failure — something the user has to fix. Drives the ✗ health icon.
    public var error: String?
    /// A benign explanation for a cycle that did nothing: disabled, paused,
    /// deferred, or skipped because the source hadn't moved. Kept apart from
    /// `error` because these used to share a field, which made a healthy skip
    /// render as a hard failure in the menu bar.
    public var note: String?
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
    /// When each mirror last synced cleanly, so a warning banner can say how
    /// long it has been broken. Engine-lifetime only — a daemon restart forgets,
    /// and the banner simply omits the date until the first clean cycle.
    private var lastSuccessAt: [String: Date] = [:]
    /// The source digest from each mirror's last completed cycle, so a
    /// change-driven pass can skip mirrors whose source hasn't moved.
    private var lastSourceDigest: [String: UInt64] = [:]
    public init() {}

    // MARK: Change notifications

    /// Call `onChange` whenever this engine's store reports a change — local
    /// edits, and remote changes once a CalDAV/Exchange pull lands. Scoped to our
    /// own store, and returns the observer token for the caller to hold.
    ///
    /// The engine owns the `EKEventStore`, so it owns the observation too; the
    /// daemon just decides what to do about it.
    public func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: nil) { _ in onChange() }
    }

    public func stopObserving(_ token: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(token)
    }

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
    ///
    /// `trigger` says why this cycle is running. A `.change` cycle may skip
    /// mirrors whose source hasn't moved; `.floor` and `.first` always do the
    /// full reconcile, which is what keeps the destination self-healing — see
    /// `syncMirror`.
    @discardableResult
    public func syncAll(_ config: Config, now: Date = Date(),
                        trigger: SyncScheduler.Reason = .floor,
                        log: ((String) -> Void)? = nil) -> [MirrorResult] {
        let reversed = reversedMirrorIds(in: config)
        return config.mirrors.map { m in
            if !m.enabled { return MirrorResult(id: m.id, name: m.name, ok: true, note: "disabled") }
            if reversed.contains(m.id) {
                log?("[\(m.id)] REFUSED: reverse of another mirror — would create a copy loop")
                return MirrorResult(id: m.id, name: m.name, ok: false,
                                    error: "Reverse of another mirror — refused to avoid a loop")
            }
            return syncMirror(m, allMirrors: config.mirrors, now: now, trigger: trigger, log: log)
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
    /// mirror's projection and any per-event control tag in the source NOTES
    /// (parsed once by the caller and passed in as `nt`).
    private func snapshot(_ src: EKEvent, tags nt: NoteTags, mirror m: Mirror) -> Snap {
        let p = m.projection
        let redact: Bool, loc: Bool, alarms: Bool, busy: Bool
        let notes: NotesMode
        if nt.forcePrivate {            // #private wins: nothing but a block
            redact = true; loc = false; notes = .none; alarms = false; busy = true
        } else if nt.forcePublic {      // #public: replicate content, availability from source
            redact = false; loc = true; notes = .full; alarms = p.alarms; busy = false
        } else {
            redact = (p.title == .redact); loc = p.location; notes = p.notes
            alarms = p.alarms; busy = (p.availability == .busy)
        }
        // Title is copied verbatim now — tags live in notes, not the title.
        let raw = src.title ?? ""
        let base = redact ? (p.titleText.isEmpty ? "Busy" : p.titleText)
                          : (raw.isEmpty ? "(no title)" : raw)
        // The prefix rides on whatever title survived redaction, so a busy-only
        // mirror can still label which mirror a block came from.
        let title = p.prefixed(base)
        // Subscribed feeds report .notSupported, which the destination coerces to
        // .busy on write, so comparing against it would flag a diff every run.
        let resolved: EKEventAvailability = busy ? .busy : src.availability
        let avail: EKEventAvailability = (resolved == .notSupported) ? .busy : resolved
        var copiedNotes: String?
        switch notes {
        case .none: copiedNotes = nil
        case .tags: copiedNotes = renderTagsOnly(src.notes)
        case .full: copiedNotes = renderCopiedNotes(src.notes, copyNotesTags: m.copyNotesTags)
        }
        // The link rides on whatever notes survived, and orthogonally to them —
        // a copy with no notes at all still gets the link if it is asked for.
        // #private suppresses it along with everything else: the point of a
        // redacted block is that it says nothing about the meeting, and a
        // meeting URL says plenty.
        if p.sourceLink && !nt.forcePrivate {
            copiedNotes = withSourceLink(copiedNotes, src.url)
        }
        return Snap(title: title, location: loc ? src.location : nil, notes: copiedNotes,
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

    // MARK: Status banner

    /// The mirror's existing banner in `dest`, if any. Searched over a wide past
    /// window because a warning can sit on the day it was raised for as long as
    /// the outage lasts.
    private func findBanner(dest: EKCalendar, mirror m: Mirror, now: Date) -> EKEvent? {
        let evs = store.events(matching: store.predicateForEvents(
            withStart: now.addingTimeInterval(-400 * 86400),
            end: now.addingTimeInterval(2 * 86400), calendars: [dest]))
        let legacyHB = m.legacyScheme.map { $0 + "-status" }
        return evs.first { ev in
            guard let sc = ev.url?.scheme, sc == Markers.heartbeatScheme || sc == legacyHB else { return false }
            if sc == legacyHB { return true }
            let opaque = ev.url!.absoluteString.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            return opaque == m.id
        }
    }

    /// Carry out whatever `HeartbeatPolicy` decided. Pinned to today, so a
    /// standing warning moves forward once a day rather than stranding itself on
    /// the date the outage began — presence is the signal here, not position.
    private func applyBanner(_ health: HeartbeatPolicy.Health, mirror m: Mirror,
                             dest: EKCalendar, existing: EKEvent?, now: Date,
                             lookUpIfMissing: Bool = true) {
        // The success path has already scanned the destination and passes what it
        // found, so it opts out of the lookup: searching again on every healthy
        // cycle would be a wide query per mirror for a banner that is almost
        // always absent — and once syncs are change-driven, cycles are frequent.
        var banner = existing
        if banner == nil, lookUpIfMissing, health != .unknown {
            banner = findBanner(dest: dest, mirror: m, now: now)
        }
        let dayStart = Calendar.current.startOfDay(for: now)
        let action = HeartbeatPolicy.decide(
            enabled: m.showHeartbeat, health: health, existingTitle: banner?.title,
            mirrorName: m.name, lastSuccess: lastSuccessAt[m.id], now: now)

        switch action {
        case .none:
            // A banner whose text is right but which is sitting on an older day
            // still needs moving to today; that is the one write an ongoing
            // outage costs, and it costs it once a day.
            if case .failing = health, let b = banner, b.startDate != dayStart {
                b.isAllDay = true; b.startDate = dayStart; b.endDate = dayStart
                try? store.save(b, span: .thisEvent, commit: true)
            }
        case .remove:
            if let b = banner { try? store.remove(b, span: .thisEvent, commit: true) }
        case .write(let title):
            let ev = banner ?? EKEvent(eventStore: store)
            ev.calendar = dest
            ev.isAllDay = true; ev.startDate = dayStart; ev.endDate = dayStart
            ev.title = title
            ev.url = Markers.heartbeatURL(mirrorId: m.id)
            try? store.save(ev, span: .thisEvent, commit: true)
        }
    }

    /// Adapt an `EKEvent` into the pure slice `EventFilters` reads, so every
    /// selection rule stays testable without EventKit.
    private func filterable(_ ev: EKEvent) -> FilterableEvent {
        let now = Date()
        // An event with no attendees is one the user made for themselves: neither
        // accepted nor pending, so the `unanswered` rule must not eat it.
        var reply = FilterableEvent.Reply.none
        if let me = ev.attendees?.first(where: { $0.isCurrentUser }) {
            switch me.participantStatus {
            case .declined: reply = .declined
            case .accepted: reply = .accepted
            case .pending, .tentative: reply = .pending
            default: reply = .none
            }
        }
        return FilterableEvent(
            title: ev.title ?? "",
            start: ev.startDate ?? now,
            end: ev.endDate ?? ev.startDate ?? now,
            isAllDay: ev.isAllDay,
            isFree: ev.availability == .free,
            isCanceled: ev.status == .canceled,
            reply: reply)
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
                            trigger: SyncScheduler.Reason = .floor,
                            log: ((String) -> Void)?) -> MirrorResult {
        var r = MirrorResult(id: m.id, name: m.name, ok: true)
        // Destination first: the banner lives there, so a failure we can't write
        // anywhere is a failure we can't announce. A missing or read-only
        // destination is exactly that case — nothing to do but report it.
        guard let dest = findCalendar(m.dest) else {
            r.ok = false; r.error = "Destination not found"; return r
        }
        guard dest.allowsContentModifications else {
            r.ok = false; r.error = "Destination is read-only"; return r
        }
        func fail(_ why: String) -> MirrorResult {
            r.ok = false; r.error = why
            applyBanner(.failing(why), mirror: m, dest: dest,
                        existing: findBanner(dest: dest, mirror: m, now: now), now: now)
            return r
        }
        guard let source = findCalendar(m.source) else { return fail("Source not found") }
        if source.calendarIdentifier == dest.calendarIdentifier {
            return fail("Source and destination are the same")
        }

        let winStart = now.addingTimeInterval(-m.windowPastDays * 86400)
        let winEnd = now.addingTimeInterval(m.windowFutureDays * 86400)

        store.refreshSourcesIfNecessary()

        let srcEvents = store.events(matching:
            store.predicateForEvents(withStart: winStart, end: winEnd, calendars: [source]))
        var srcList: [EKEvent] = []
        var snaps: [Snap] = []                 // parallel to srcList; built once per event
        var desiredList: [Reconciler.Desired] = []
        for ev in srcEvents {
            if isMirrorArtifact(ev, mirrors: allMirrors) { continue }   // don't re-mirror a copy/heartbeat
            let nt = scanNoteTags(ev.notes)
            if nt.skip { continue }                                     // honor #nomirror
            // Property selection (declined/canceled/all-day/hours/…) runs before
            // the tag filter and is FINAL: #public and #private govern how much
            // of an event crosses over, not whether it does, so neither rescues
            // an event a filter dropped.
            if !m.filters.admits(filterable(ev)) { continue }
            if let f = m.tagFilter, !f.admits(nt) { continue }          // include/reject by notes tag
            let snap = snapshot(ev, tags: nt, mirror: m)
            srcList.append(ev)
            snaps.append(snap)
            // Fingerprint uses the PROJECTED title so a redacted copy still
            // fuzzy-matches its source (the copy carries the projected title).
            desiredList.append(.init(
                key: keyFor(ev, now: now),
                fingerprint: fingerprintOf(title: snap.title, start: ev.startDate,
                                           end: ev.endDate, allDay: ev.isAllDay, now: now)))
        }


        // Has this mirror's source actually moved? Digesting what we want is
        // cheap; the settle-wait and destination scan below are not. On a
        // change-driven cycle a store-wide notification means SOMETHING changed
        // somewhere — usually in one calendar — and without this every mirror
        // pays full price for it.
        //
        // Only ever skipped on a `.change` cycle. The scheduled floor always does
        // the full reconcile, so the destination stays self-healing: a copy
        // someone deleted by hand is restored within the interval, and the
        // fast path can never quietly become the only path.
        let digest = SourceDigest.of(desiredList)
        if trigger == .change, lastSuccessAt[m.id] != nil, lastSourceDigest[m.id] == digest {
            r.ok = true; r.note = "unchanged"
            return r
        }

        // --- Stale-snapshot protection ---------------------------------------
        // A fresh EKEventStore serves a partial CalDAV snapshot until it settles.
        // Refresh, then wait until the destination's owned-copy count is stable
        // across reads; SnapshotGuard then vetoes acting on an unsettled or
        // collapsed view (which is what created/kept duplicates). Runs on a
        // background queue, so the brief blocking waits are fine.
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
            r.ok = true; r.note = "deferred: \(why)"
            log?("[\(m.id)] DEFER — \(why)")
            // .unknown, deliberately: a deferral neither raises a warning nor
            // clears one that is already up.
            applyBanner(.unknown, mirror: m, dest: dest, existing: nil, now: now)
            return r
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

        // Which fields disagree, rather than merely whether any do. The counts
        // go into the cycle's log line: a mirror that rewrites the same events
        // every run is a real bug — wasted writes on a calendar you share, and
        // under realtime a periodic write is the one shape that can re-trigger
        // the sync that made it — and "~3" alone gives you nothing to chase.
        func diffFields(_ copy: EKEvent, _ src: EKEvent, _ s: Snap, key: String) -> [String] {
            var out: [String] = []
            if copy.title != s.title { out.append("title") }
            if copy.startDate != src.startDate { out.append("start") }
            if copy.endDate != src.endDate { out.append("end") }
            if copy.isAllDay != src.isAllDay { out.append("allDay") }
            if (copy.location ?? "") != (s.location ?? "") { out.append("location") }
            if (copy.notes ?? "") != (s.notes ?? "") { out.append("notes") }
            if copy.availability != s.availability { out.append("availability") }
            if alarmSig(copy.alarms) != s.alarmSig { out.append("alarms") }
            if copy.url != Markers.copyURL(mirrorId: m.id, key: key) { out.append("marker") }
            return out
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
        var changedFields: [String: Int] = [:]
        var staleKeys = 0
        for (di, ref) in plan.match {
            let copy = owned[ref], src = srcList[di], s = snaps[di], key = desiredList[di].key
            let fields = diffFields(copy, src, s, key: key)

            // A marker-only difference means the copy's CONTENT is already right
            // and only its occurrence key is older than the one the source hashes
            // to now. Some feeds — on-call rotations especially — regenerate
            // `calendarItemExternalIdentifier` on every fetch, so the key churns
            // even though nothing about the event moved. Re-stamping buys nothing
            // and rewrites the same events forever: wasted writes on a calendar
            // you share, and under realtime a periodic write is the one shape
            // that can re-trigger the sync that produced it.
            //
            // Leaving the older key is safe. It still names this mirror, so
            // ownership and the delete-sweep are unaffected; the reconciler's
            // fingerprint pass re-adopts the copy each cycle at no cost. And any
            // real content change re-stamps anyway, because `apply` always
            // rewrites the marker.
            if fields == ["marker"] {
                staleKeys += 1
                r.unchanged += 1
            } else if !fields.isEmpty {
                for f in fields { changedFields[f, default: 0] += 1 }
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

        // Status banner. Healthy is silent — this only clears whatever an
        // earlier failure left behind.
        lastSuccessAt[m.id] = now
        lastSourceDigest[m.id] = digest
        applyBanner(.ok, mirror: m, dest: dest, existing: heartbeat, now: now,
                    lookUpIfMissing: false)

        // Trust this cycle's owned-copy count as the baseline the guard compares
        // future (possibly stale) snapshots against.
        lastOwned[m.id] = r.total

        var why = changedFields.isEmpty ? ""
            : " · changed: " + changedFields.sorted { $0.key < $1.key }
                .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        // Surfaced rather than silently absorbed: it means the source feed
        // regenerates its event identifiers, which is worth knowing about even
        // though it now costs nothing.
        if staleKeys > 0 { why += " · stale keys×\(staleKeys) (source re-issues ids)" }
        log?("[\(m.id)] +\(r.created) ~\(r.updated) =\(r.unchanged) -\(r.deleted)\(why)")
        return r
    }
}
