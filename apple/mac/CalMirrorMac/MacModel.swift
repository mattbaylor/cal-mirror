import SwiftUI
import ServiceManagement
import CalMirrorKit

/// Sandbox-safe Mac model: the engine runs in-process on a timer, config lives
/// in the app container, and launch-at-login uses SMAppService. No LaunchAgents,
/// no launchctl — everything the App Sandbox forbids is gone.
@MainActor
final class MacModel: ObservableObject {
    @Published var config = Config.empty
    @Published var statuses: [String: MirrorResult] = [:]
    @Published var calendars: [CalendarInfo] = []
    @Published var access = false
    @Published var lastRun: Date?
    @Published var syncing = false
    @Published var launchAtLogin = false

    private let engine = MirrorEngine()
    private var timer: Timer?

    private var configURL: URL {
        let dir = try! FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return dir.appendingPathComponent("config.json")
    }

    init() {
        config = ConfigStore.load(from: configURL)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        scheduleTimer()
        Task { await bootstrap() }
    }

    func bootstrap() async {
        access = await engine.requestAccess()
        if access {
            calendars = engine.calendars()
            await syncNow()
        }
    }

    // MARK: Sync

    func scheduleTimer() {
        timer?.invalidate(); timer = nil
        guard !config.paused, config.intervalSeconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.intervalSeconds), repeats: true) { [weak self] _ in
            Task { await self?.syncNow() }
        }
    }

    func syncNow() async {
        guard access, !syncing else { return }
        syncing = true
        let cfg = config
        let results = await Task.detached { MirrorEngine().syncAll(cfg) }.value
        statuses = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        lastRun = Date()
        syncing = false
    }

    // MARK: Config edits

    func save() { try? ConfigStore.save(config, to: configURL); scheduleTimer() }

    func togglePause() { config.paused.toggle(); save() }
    func setInterval(_ seconds: Int) { config.intervalSeconds = seconds; save() }
    func toggleEnabled(_ id: String) {
        if let i = config.mirrors.firstIndex(where: { $0.id == id }) { config.mirrors[i].enabled.toggle(); save() }
    }
    func toggleHeartbeat(_ id: String) {
        if let i = config.mirrors.firstIndex(where: { $0.id == id }) { config.mirrors[i].showHeartbeat.toggle(); save() }
    }
    func addMirror() {
        config.mirrors.append(Mirror(id: "m\(Int(Date().timeIntervalSince1970))",
            name: "New mirror", source: CalRef(title: ""), dest: CalRef(title: "")))
        save()
    }
    func delete(_ id: String) { config.mirrors.removeAll { $0.id == id }; save() }

    /// Would (source -> dest) reverse an existing mirror? (blocks copy loops)
    func reverseConflict(source: CalRef, dest: CalRef, excluding id: String) -> Mirror? {
        engine.reverseConflict(source: source, dest: dest, in: config.mirrors, excluding: id)
    }

    // MARK: Login item (App-Store-safe replacement for the LaunchAgent)

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SMAppService error: \(error)")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: Health (for the menu-bar icon)

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
    var headline: String {
        if config.paused { return "Paused" }
        guard let last = lastRun else { return "No sync yet" }
        let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .short
        return "Last sync \(rel.localizedString(for: last, relativeTo: Date()))"
    }
}
