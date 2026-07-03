import SwiftUI
import BackgroundTasks
import CalMirrorKit

/// Background refresh. iOS grants these *opportunistically* — this is a
/// best-effort top-up, NOT a guaranteed schedule. The reliable path is
/// on-open / pull-to-refresh in the UI.
enum BackgroundSync {
    static let refreshID = "io.github.mattbaylor.cal-mirror.refresh"

    static func schedule(after seconds: TimeInterval) {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: max(60, seconds))
        try? BGTaskScheduler.shared.submit(req)
    }

    @discardableResult
    static func run() async -> Bool {
        let engine = MirrorEngine()
        guard await engine.requestAccess() else { return false }
        let cfg = ConfigStore.load(from: Store.configURL)
        guard !cfg.paused else { return true }
        let results = engine.syncAll(cfg)
        UserDefaults.standard.set(Date(), forKey: "lastRun")
        return results.allSatisfy { $0.ok }
    }
}

@main
struct CalMirrorApp: App {
    @StateObject private var model = Store()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
        }
        // System-driven background refresh; reschedules itself after each run.
        .backgroundTask(.appRefresh(BackgroundSync.refreshID)) {
            await BackgroundSync.run()
            BackgroundSync.schedule(after: 30 * 60)
        }
    }
}
