import SwiftUI
import CalMirrorKit
#if os(macOS)
import ServiceManagement
#endif

/// Shared view-model for both apps. Cross-platform logic lives here; the only
/// platform-specific bits are the macOS timer + login item (`#if os(macOS)`).
/// iOS drives syncs on-open / pull-to-refresh and schedules `BGAppRefreshTask`
/// from the app scene, so it needs no timer here.
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
    private var timer: Timer?
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
        config.mirrors.append(Mirror(id: "m\(Int(Date().timeIntervalSince1970))",
            name: "New mirror", source: CalRef(title: ""), dest: CalRef(title: "")))
        save()
    }
    func delete(id: String) { config.mirrors.removeAll { $0.id == id }; save() }
    func delete(_ id: String) { delete(id: id) }
    func togglePause() { config.paused.toggle(); save() }
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
    var overallIcon: String {
        if config.paused { return "pause.circle" }
        let enabled = config.mirrors.filter { $0.enabled }
        if enabled.isEmpty { return "circle.dashed" }
        let icons = enabled.map { iconFor($0.id) }
        if icons.contains("xmark.octagon.fill") { return "xmark.octagon.fill" }
        if icons.contains("exclamationmark.triangle.fill") { return "exclamationmark.triangle.fill" }
        if icons.contains("questionmark.circle") { return "questionmark.circle" }
        return "checkmark.circle.fill"
    }
    func iconFor(_ id: String) -> String {
        if config.paused { return "pause.circle" }
        guard let s = statuses[id] else { return "questionmark.circle" }
        if let e = s.error, !e.isEmpty { return e == "disabled" ? "minus.circle" : "xmark.octagon.fill" }
        if !s.ok { return "xmark.octagon.fill" }
        if let last = lastRun, Date().timeIntervalSince(last) > Double(config.intervalSeconds) * 2 + 120 {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    // MARK: macOS-only (timer + login item)

    #if os(macOS)
    func scheduleTimer() {
        timer?.invalidate(); timer = nil
        guard !config.paused, config.intervalSeconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.intervalSeconds), repeats: true) { [weak self] _ in
            Task { await self?.syncNow() }
        }
    }
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("SMAppService error: \(error)") }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
    #endif
}
