import SwiftUI
import CalMirrorKit

/// The request page's corner of the view model.
///
/// `Config.requestPage` is optional and absent on every config written before
/// 2.0, so the UI needs a non-optional thing to bind to without that act
/// meaning anything. Materialising a default `RequestPageConfig` is safe
/// precisely because `enabled` is false in it — the same guarantee
/// `cmk-check` asserts on the decode paths. Reading this property, binding a
/// control to it, even writing a policy through it, never turns the page on.
extension Store {

    /// Never nil, never persisted by the act of reading.
    var requestPage: RequestPageConfig {
        get { config.requestPage ?? RequestPageConfig() }
        set { config.requestPage = newValue }
    }

    /// For the setup screens. Saves on every edit, as the mirror editor does —
    /// there is no Done button to hang a save on, and a policy half-written
    /// when the app is killed should survive.
    var requestPageBinding: Binding<RequestPageConfig> {
        Binding(get: { self.requestPage },
                set: { self.requestPage = $0; self.save() })
    }

    /// Whether the owner has ever engaged with this. Distinct from `enabled`:
    /// a page can be fully configured and still off, which is exactly the
    /// state someone who backs out of setup is left in.
    var hasRequestPage: Bool { config.requestPage != nil }

    /// Writable calendars, for the "use for requests" choice. Read-only ones
    /// are still listed — the row disables its own control and says why, which
    /// is more use than a calendar silently missing from the list.
    var requestCalendarCandidates: [CalendarInfo] { calendars.filter(\.writable) }
}
