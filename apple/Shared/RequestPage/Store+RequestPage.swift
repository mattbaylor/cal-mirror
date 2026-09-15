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

    /// One per process, like the engine. `StoreKitSubscriptions` holds
    /// StoreKit's own listeners, and two of them would answer the same
    /// renewal twice.
    fileprivate static let sharedSubscriptions: SubscriptionStore = StoreKitSubscriptions()

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

    /// StoreKit, behind the Kit's protocol. Constructing it is inert — no
    /// product load, no network — so holding one costs nothing for the owner
    /// who never opens the setup. The first call is `offers()`, on screen 7.
    var subscriptions: SubscriptionStore { Store.sharedSubscriptions }

    /// The device side of the dead drop. Built on demand rather than at launch
    /// for the same reason: a coordinator that exists has still never spoken to
    /// anything, but building it where it is used keeps that obvious.
    func requestCoordinator() -> RequestPageCoordinator {
        RequestPageCoordinator(engine: engine, tokens: KeychainTokenStore())
    }

    /// Create the page with Apple's signed transaction, then persist the slug.
    /// Returns rather than throws so the offer screen can show what happened —
    /// the one failure here (Apple charged, the service did not answer) needs
    /// its own words, not a generic alert.
    func createRequestPage(transaction: String) async -> Result<Void, Error> {
        var page = requestPage
        do {
            try await requestCoordinator().create(page: &page, transaction: transaction)
            requestPage = page
            save()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// What the preview derives against. Handed to the view as a function so
    /// the same view renders from a fixture with no EventKit — which is how it
    /// gets screenshotted from a synthetic config rather than a real calendar.
    var busySource: (_ calendars: [CalRef], _ from: Date, _ to: Date) -> [BusyInterval] {
        { [engine] cals, from, to in engine.busyIntervals(in: cals, from: from, to: to) }
    }
}
