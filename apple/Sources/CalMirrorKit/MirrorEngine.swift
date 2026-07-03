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
public final class MirrorEngine {
    private let store = EKEventStore()
    public init() {}

    // MARK: Access

    public func requestAccess() async -> Bool {
        do { return try await store.requestFullAccessToEvents() } catch { return false }
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
        let ext = ev.calendarItemExternalIdentifier ?? ev.eventIdentifier ?? UUID().uuidString
        let start = Int((ev.startDate ?? now).timeIntervalSince1970)
        return Data("\(ext)#\(start)".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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

        let srcEvents = store.events(matching:
            store.predicateForEvents(withStart: winStart, end: winEnd, calendars: [source]))
        var desired: [String: EKEvent] = [:]
        for ev in srcEvents { desired[keyFor(ev, now: now)] = ev }

        let dstEvents = store.events(matching: store.predicateForEvents(
            withStart: winStart.addingTimeInterval(-86400),
            end: winEnd.addingTimeInterval(86400), calendars: [dest]))
        var existing: [String: EKEvent] = [:]
        var heartbeat: EKEvent?
        let legacyHB = m.legacyScheme.map { $0 + "-status" }
        for ev in dstEvents {
            if let sc = ev.url?.scheme, sc == Markers.heartbeatScheme || sc == legacyHB {
                let opaque = ev.url!.absoluteString.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                if sc == legacyHB || opaque == m.id { heartbeat = ev }
                continue
            }
            if let owner = Markers.owner(of: ev.url, mirrors: allMirrors), owner.id == m.id {
                existing[owner.key] = ev
            }
        }

        func differ(_ copy: EKEvent, _ src: EKEvent) -> Bool {
            copy.title != (src.title ?? "") || copy.startDate != src.startDate ||
            copy.endDate != src.endDate || copy.isAllDay != src.isAllDay ||
            (copy.location ?? "") != (src.location ?? "") ||
            copy.url != Markers.copyURL(mirrorId: m.id, key: keyFor(src, now: now))
        }
        func apply(_ copy: EKEvent, _ src: EKEvent, key: String) {
            copy.title = src.title ?? "(no title)"
            copy.startDate = src.startDate; copy.endDate = src.endDate
            copy.isAllDay = src.isAllDay; copy.location = src.location; copy.timeZone = src.timeZone
            copy.url = Markers.copyURL(mirrorId: m.id, key: key); copy.calendar = dest
        }
        var pending = 0
        func maybeCommit(_ force: Bool = false) {
            if force || pending >= 50 { try? store.commit(); pending = 0 }
        }

        for (key, src) in desired {
            if let copy = existing[key] {
                if differ(copy, src) {
                    apply(copy, src, key: key)
                    try? store.save(copy, span: .thisEvent, commit: false); pending += 1
                    r.updated += 1
                } else { r.unchanged += 1 }
            } else {
                let c = EKEvent(eventStore: store); apply(c, src, key: key)
                try? store.save(c, span: .thisEvent, commit: false); pending += 1
                r.created += 1
            }
            maybeCommit()
        }
        for (key, copy) in existing where desired[key] == nil {
            try? store.remove(copy, span: .thisEvent, commit: false); pending += 1
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

        log?("[\(m.id)] +\(r.created) ~\(r.updated) =\(r.unchanged) -\(r.deleted)")
        return r
    }
}
