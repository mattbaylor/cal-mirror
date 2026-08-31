import SwiftUI
import CalMirrorKit
#if os(macOS)
import ServiceManagement
#endif

/// Shared view-model for both apps. Cross-platform logic lives here; the only
/// platform-specific bits are the macOS sync loop + login item (`#if os(macOS)`).
/// iOS drives syncs on-open / pull-to-refresh and schedules `BGAppRefreshTask`
/// from the app scene, so it needs no loop here.
@MainActor
final class Store: ObservableObject {
    @Published var config = Config.empty
    @Published var statuses: [String: MirrorResult] = [:]
    @Published var calendars: [CalendarInfo] = []
    @Published var access = false
    @Published var lastRun: Date?
    @Published var syncing = false
    #if os(macOS)
    @Published var launchAtLogin = false
    /// Whether the change observer is actually up, so the UI can tell a working
    /// realtime setup from one that merely has the switch on.
    @Published var observing = false
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var scheduler = SyncScheduler()
    private var observerToken: NSObjectProtocol?
    #endif

    private let engine = MirrorEngine()

    /// Config lives in the app container's Application Support (sandbox-safe).
    /// `nonisolated` so background code (iOS `BackgroundSync`) can read it too.
    nonisolated static var configURL: URL {
        let dir = try! FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return dir.appendingPathComponent("config.json")
    }

    init() {
        config = ConfigStore.load(from: Store.configURL)
        lastRun = UserDefaults.standard.object(forKey: "lastRun") as? Date
        #if os(macOS)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        scheduleTimer()
        #endif
        Task { await bootstrap() }
    }

    func bootstrap() async {
        access = await engine.requestAccess()
        if access { calendars = engine.calendars(); await syncNow() }
    }

    func save() {
        try? ConfigStore.save(config, to: Store.configURL)
        #if os(macOS)
        scheduleTimer()
        #endif
    }

    func syncNow() async {
        guard access, !syncing else { return }
        syncing = true
        let cfg = config
        // Reuse the ONE long-lived engine/store (not a fresh one per sync): a
        // persistent EKEventStore stays warm, and the engine's per-mirror
        // stability guard needs its baseline count to persist across syncs.
        let eng = engine
        eng.refreshSources()
        let results = await Task.detached { eng.syncAll(cfg) }.value
        statuses = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        lastRun = Date()
        UserDefaults.standard.set(lastRun, forKey: "lastRun")
        syncing = false
    }

    // MARK: Config edits

    func addMirror() {
        config.mirrors.append(Mirror(id: freshMirrorId(),
            name: "New mirror", source: CalRef(title: ""), dest: CalRef(title: "")))
        save()
    }
    /// Unique mirror id. The old timestamp-second scheme collided when two mirrors
    /// were added within the same second, making them share a marker tag.
    private func freshMirrorId() -> String {
        func gen() -> String { "m\(UUID().uuidString.prefix(12))" }
        var id = gen()
        while config.mirrors.contains(where: { $0.id == id }) { id = gen() }
        return id
    }
    func delete(id: String) { config.mirrors.removeAll { $0.id == id }; save() }
    func delete(_ id: String) { delete(id: id) }
    func togglePause() { config.paused.toggle(); save() }
    func toggleDedupe() { config.dedupeDestinations.toggle(); save() }
    func setInterval(_ seconds: Int) { config.intervalSeconds = seconds; save() }
    func toggleEnabled(_ id: String) {
        if let i = config.mirrors.firstIndex(where: { $0.id == id }) { config.mirrors[i].enabled.toggle(); save() }
    }
    func toggleHeartbeat(_ id: String) {
        if let i = config.mirrors.firstIndex(where: { $0.id == id }) { config.mirrors[i].showHeartbeat.toggle(); save() }
    }

    // MARK: Reverse-direction guard (both names, one implementation)

    func reverseConflict(source: CalRef, dest: CalRef, excluding id: String) -> Mirror? {
        engine.reverseConflict(source: source, dest: dest, in: config.mirrors, excluding: id)
    }
    func wouldReverse(source: CalRef, dest: CalRef, excluding id: String) -> Mirror? {
        reverseConflict(source: source, dest: dest, excluding: id)
    }

    // MARK: Health (menu-bar icon / status text)

    var headline: String {
        if config.paused { return "Paused" }
        guard let last = lastRun else { return "No sync yet" }
        let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .short
        return "Last sync \(rel.localizedString(for: last, relativeTo: Date()))"
    }
    // What the menu-bar icon shows. Rows inside the menu keep their SF Symbols
    // (iconFor) — a face next to a line of text reads worse than a checkmark.
    #if os(macOS)
    var menuBarState: MenuBarState {
        if config.paused { return .paused }
        let enabled = config.mirrors.filter { $0.enabled }
        if enabled.isEmpty { return .unconfigured }
        let icons = enabled.map { iconFor($0.id) }
        if icons.contains("xmark.octagon.fill") { return .failing }
        // Stale and never-run both fold into degraded: either way the mirror is
        // not known to be current.
        if icons.contains("exclamationmark.triangle.fill") { return .degraded }
        if icons.contains("questionmark.circle") { return .degraded }
        return .ok
    }
    #endif
    func iconFor(_ id: String) -> String {
        if config.paused { return "pause.circle" }
        guard let s = statuses[id] else { return "questionmark.circle" }
        if let e = s.error, !e.isEmpty { return "xmark.octagon.fill" }
        if s.note == "disabled" { return "minus.circle" }
        if !s.ok { return "xmark.octagon.fill" }
        if let last = lastRun, Date().timeIntervalSince(last) > Double(config.intervalSeconds) * 2 + 120 {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    // MARK: macOS-only (sync loop + login item)

    #if os(macOS)
    /// The same three-way decision the standalone daemon makes — debounced
    /// calendar changes, a minimum gap between change-driven runs, and the
    /// scheduled floor — rather than a fixed repeating Timer.
    ///
    /// The floor never goes away. EKEventStoreChanged is best-effort: subscribed
    /// ICS feeds refresh without announcing it and sleep drops notifications
    /// outright, so without a backstop a missed notification means a mirror
    /// stale forever with nothing to notice. With realtime on, the floor is
    /// pinned to five minutes and the configured interval steps aside.
    func scheduleTimer() {
        loop?.cancel()
        applyObserver()
        guard !config.paused else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.step()
                guard wait > 0 else { continue }
                await self.nap(wait)
            }
        }
    }

    /// One pass: decide, and either sync or report how long to wait.
    private func step() async -> TimeInterval {
        switch scheduler.decide(now: Date(), intervalSeconds: config.effectiveIntervalSeconds) {
        case .sync:
            await syncNow()
            let done = Date()
            // Order matters: open the self-write window BEFORE clearing the
            // pending burst, so an echo of our own writes landing in between is
            // suppressed rather than scheduling the cycle that just finished all
            // over again.
            scheduler.noteWrite(at: done)
            scheduler.noteSyncFinished(at: done)
            return 0
        case .wait(let seconds):
            return seconds
        }
    }

    /// Sleep, but let a calendar change cut it short.
    private func nap(_ seconds: TimeInterval) async {
        // Explicitly Task<Void, Never>: `try?` would make the closure return
        // Void? and the type would not match `sleeper`.
        let t = Task<Void, Never> {
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { }
        }
        sleeper = t
        await t.value          // returns immediately once cancelled
        sleeper = nil
    }

    /// Follow the config: realtime can be switched on or off at any time.
    private func applyObserver() {
        let wanted = config.realtime && !config.paused
        if wanted, observerToken == nil {
            observerToken = engine.observeChanges { [weak self] in
                Task { @MainActor in self?.noteCalendarChange() }
            }
            observing = true
        } else if !wanted, let token = observerToken {
            engine.stopObserving(token)
            observerToken = nil
            observing = false
        }
    }

    private func noteCalendarChange() {
        // Only interrupt the wait for a change we actually intend to act on —
        // our own write echoing back should not even wake us.
        if scheduler.noteChange(at: Date()) { sleeper?.cancel() }
    }

    func toggleRealtime() {
        config.realtime.toggle()
        save()
    }
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("SMAppService error: \(error)") }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
    #endif
}
