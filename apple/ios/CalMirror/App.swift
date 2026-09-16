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

/// Owns the store and the notification delegate, because both have to exist
/// before launch finishes. Apple's rule for `UNUserNotificationCenter` is that
/// its delegate is assigned before `didFinishLaunching` returns; a delegate
/// set from a view's `onAppear` misses the one case that matters — Accept
/// tapped on a lock screen, which launches the app in the background with no
/// window and no view to appear. The store lives here for the same reason:
/// the response needs somewhere to go the moment it arrives.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = Store()
    let notifications = RequestNotificationDelegate()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        notifications.store = model
        UNUserNotificationCenter.current().delegate = notifications
        let model = model
        BackgroundSync.collector = { Task { await model.collectRequests() } }
        return true
    }
}

@main
struct CalMirrorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.notifications)
        }
        // System-driven background refresh; reschedules itself after each run.
        .backgroundTask(.appRefresh(BackgroundSync.refreshID)) {
            await BackgroundSync.run()
            BackgroundSync.schedule(after: BackgroundSync.configuredInterval)
        }
    }
}
