import SwiftUI
import CalMirrorKit

@MainActor
final class AppModel: ObservableObject {
    @Published var config = Config.empty
    @Published var calendars: [CalendarInfo] = []
    @Published var access = false
    @Published var statuses: [String: MirrorResult] = [:]
    @Published var lastRun: Date?
    @Published var syncing = false

    private let engine = MirrorEngine()

    init() {
        config = ConfigStore.load(from: AppPaths.configURL)
        lastRun = UserDefaults.standard.object(forKey: "lastRun") as? Date
        Task { await bootstrap() }
    }

    func bootstrap() async {
        access = await engine.requestAccess()
        if access { calendars = engine.calendars() }
    }

    func save() { try? ConfigStore.save(config, to: AppPaths.configURL) }

    func syncNow() async {
        if !access { await bootstrap(); guard access else { return } }
        syncing = true
        let cfg = config
        // Run EventKit work off the main actor so the UI stays responsive.
        // A fresh engine shares the app's process-wide Calendar grant.
        let results = await Task.detached { MirrorEngine().syncAll(cfg) }.value
        statuses = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        lastRun = Date()
        UserDefaults.standard.set(lastRun, forKey: "lastRun")
        syncing = false
        BackgroundSync.schedule(after: TimeInterval(config.intervalSeconds))
    }

    /// Would a (source -> dest) mirror reverse an existing one? Returns it.
    func wouldReverse(source: CalRef, dest: CalRef, excluding id: String) -> Mirror? {
        engine.reverseConflict(source: source, dest: dest, in: config.mirrors, excluding: id)
    }

    func addMirror() {
        config.mirrors.append(Mirror(
            id: "m\(Int(Date().timeIntervalSince1970))", name: "New mirror",
            source: CalRef(title: ""), dest: CalRef(title: "")))
        save()
    }

    func delete(id: String) {
        config.mirrors.removeAll { $0.id == id }
        save()
    }
}
