import AppIntents
import CalMirrorKit
import Foundation

/// "Sync Now" as a Shortcuts action, on iPhone, iPad and Mac.
///
/// Deliberately engine-only rather than driving `Store`. An intent runs from the
/// Shortcuts app, an automation, a Home Screen tile or Siri, and in none of
/// those cases is there a live view model to talk to — this is the same path the
/// iOS background task already takes.
struct SyncNowIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Now"
    static var description = IntentDescription(
        "Copies every enabled mirror once, right now, instead of waiting for the next scheduled run.")

    /// Runs in the background. Bringing the app forward to press its own button
    /// would defeat the point of automating it.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let engine = MirrorEngine()

        // Calendar access is a one-time prompt the app has to show; an intent
        // firing from an automation cannot present it, so say what to do rather
        // than failing silently.
        guard await engine.requestAccess() else {
            return .result(dialog: "Calendar Mirror doesn't have calendar access yet. Open the app once to allow it.")
        }

        let cfg = ConfigStore.load(from: Store.configURL)
        guard !cfg.mirrors.isEmpty else {
            return .result(dialog: "No mirrors are set up yet.")
        }
        guard !cfg.paused else {
            return .result(dialog: "Syncing is paused.")
        }

        // Off the main actor, the way Store.syncNow does it: syncAll walks every
        // mirror's window and is far too slow to hold the caller on.
        engine.refreshSources()
        let eng = engine
        let results = await Task.detached { eng.syncAll(cfg) }.value
        UserDefaults.standard.set(Date(), forKey: "lastRun")

        return .result(dialog: IntentDialog(stringLiteral: Self.summary(results)))
    }

    /// What the shortcut says when it finishes. Reports what changed rather than
    /// "done", because the useful question after a manual sync is whether it
    /// actually moved anything.
    static func summary(_ results: [MirrorResult]) -> String {
        let failed = results.filter { $0.error != nil }
        if !failed.isEmpty {
            let names = failed.map { $0.name }.joined(separator: ", ")
            return failed.count == 1
                ? "\(names) failed to sync: \(failed[0].error ?? "unknown error")."
                : "\(failed.count) mirrors failed to sync: \(names)."
        }
        let created = results.reduce(0) { $0 + $1.created }
        let updated = results.reduce(0) { $0 + $1.updated }
        let deleted = results.reduce(0) { $0 + $1.deleted }
        if created == 0 && updated == 0 && deleted == 0 {
            return results.count == 1 ? "1 mirror checked, nothing to change."
                                      : "\(results.count) mirrors checked, nothing to change."
        }
        var bits: [String] = []
        if created > 0 { bits.append("\(created) added") }
        if updated > 0 { bits.append("\(updated) updated") }
        if deleted > 0 { bits.append("\(deleted) removed") }
        return bits.joined(separator: ", ") + "."
    }
}

/// Offers the action in Shortcuts and to Siri without the user building anything
/// first. The phrases must contain `\(.applicationName)`; Apple rejects
/// providers whose phrases do not.
struct CalMirrorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: ["Sync my calendars with \(.applicationName)",
                      "Sync \(.applicationName) now"],
            shortTitle: "Sync Now",
            systemImageName: "arrow.triangle.2.circlepath")
    }
}
