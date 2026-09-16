import AppIntents
import CalMirrorKit
import Foundation

/// "Send times" as a Shortcuts action and a Siri phrase, on iPhone, iPad and
/// Mac — and, on macOS 26, in Spotlight's actions. Returns the line so a
/// shortcut can hand it straight to Messages or Mail; the dialog is the
/// same line, so Siri reads it back.
///
/// Engine-only, like `SyncNowIntent`: there is no live view model when this
/// runs from a shortcut, and there need not be.
struct SendTimesIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Times"
    static var description = IntentDescription(
        "Your next three free times as a line of text, in your time zone, with your request page's link if you have one.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let engine = MirrorEngine()
        guard await engine.requestAccess() else {
            return .result(value: "", dialog: "Calendar Mirror doesn't have calendar access yet. Open the app once to allow it.")
        }
        let cfg = ConfigStore.load(from: Store.configURL)
        let calendars = engine.calendars()
        guard let line = SendTimesSource.text(config: cfg, engine: engine, calendars: calendars) else {
            let days = (cfg.requestPage ?? RequestPageConfig()).policy.horizonDays
            return .result(value: "", dialog: IntentDialog(stringLiteral: String(format: RequestCopy.SendTimes.empty, days)))
        }
        return .result(value: line, dialog: IntentDialog(stringLiteral: line))
    }
}
