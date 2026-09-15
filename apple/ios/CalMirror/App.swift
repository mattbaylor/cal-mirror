import SwiftUI
import BackgroundTasks
import UserNotifications
import CalMirrorKit

/// Background refresh. iOS grants these *opportunistically* — this is a
/// best-effort top-up, NOT a guaranteed schedule. The reliable path is
/// on-open / pull-to-refresh in the UI.
enum BackgroundSync {
    static let refreshID = "io.github.mattbaylor.cal-mirror.refresh"

    /// Offered in the UI. Nothing below 15 min is worth showing: iOS throttles
    /// app refresh well above that, so a tighter choice would only mislead.
    static let intervalChoices: [(String, Int)] =
        [("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200)]

    static func schedule(after seconds: TimeInterval) {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: max(60, seconds))
        try? BGTaskScheduler.shared.submit(req)
    }

    /// The user's configured interval, re-read each time. The background task
    /// reschedules itself, so a hardcoded period here would quietly override the
    /// setting after the first run and never honor it again.
    static var configuredInterval: TimeInterval {
        TimeInterval(ConfigStore.load(from: Store.configURL).intervalSeconds)
    }

    /// Set by the app so a background refresh can collect requests without
    /// this enum needing to know what a Store is.
    @MainActor static var collector: (() -> Void)?

    @discardableResult
    static func run() async -> Bool {
        let engine = MirrorEngine()
        guard await engine.requestAccess() else { return false }
        let cfg = ConfigStore.load(from: Store.configURL)
        guard !cfg.paused else { return true }
        let results = engine.syncAll(cfg)
        UserDefaults.standard.set(Date(), forKey: "lastRun")
        // Collection rides the same background refresh, because decisions.md
        // settled that the pace is the sync setting the owner already chose
        // rather than a second schedule to explain.
        await MainActor.run { collector?() }
        return results.allSatisfy { $0.ok }
    }
}

@main
struct CalMirrorApp: App {
    @StateObject private var model = Store()
    @StateObject private var notifications = RequestNotificationDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(notifications)
                .onAppear {
                    // Wired here rather than in Store: iOS can deliver a
                    // notification response before any view exists, and an
                    // Accept that only worked with a window open would fail
                    // exactly when it was most useful.
                    notifications.store = model
                    UNUserNotificationCenter.current().delegate = notifications
                    BackgroundSync.collector = { Task { await model.collectRequests() } }
                }
        }
        // System-driven background refresh; reschedules itself after each run.
        .backgroundTask(.appRefresh(BackgroundSync.refreshID)) {
            await BackgroundSync.run()
            BackgroundSync.schedule(after: BackgroundSync.configuredInterval)
        }
    }
}
