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

    /// A page this device has the key to and no config for: the token came
    /// through iCloud Keychain (a reinstall, or a second device) and the
    /// config, which is local, did not. Read from the Keychain once at
    /// launch, and only when there is no page configured — a Keychain read
    /// is local, so the no-network-before-opting-in promise is untouched.
    func findRecoverableRequestPage() {
        guard config.requestPage == nil else { recoverableSlug = nil; return }
        recoverableSlug = (try? KeychainTokenStore().slugs())?.first
    }

    /// Carry on with the page the Keychain has the key to: the slug is
    /// restored and the page turned on, so requests are collected from the
    /// next poll; the calendars, name and policy are local and the owner
    /// re-enters them — `isReady` keeps the page from being republished
    /// until they have. Nothing about the page on the service changes.
    func reattachRequestPage() {
        guard let slug = recoverableSlug else { return }
        requestPage = RequestPageConfig(slug: slug, enabled: true)
        recoverableSlug = nil
        save()
    }

    /// Zero-decision setup (`decisions.md`, *Setup with zero decisions, and
    /// the preview before the offer*): turning the row on infers the rest,
    /// and the first thing shown is the preview. Writable calendars block;
    /// subscribed and read-only ones (holidays, a sports feed) do not; the
    /// calendar new events go to receives; the policy is its defaults. Only
    /// what is empty is inferred, so an owner who already chose keeps their
    /// choices, and every inference is a row away under *Adjust*.
    ///
    /// The display name is the one thing not inferred on iOS: the Me card
    /// would need a Contacts prompt, and a system dialog asking for Contacts
    /// to guess a label is a worse first minute than one text field. The
    /// Mac has the account's full name without asking, and uses it.
    func inferRequestPage() {
        var page = requestPage
        page.infer(calendars: calendars, receiver: fixture ? nil : engine.defaultCalendar())
        #if os(macOS)
        if page.displayName.trimmingCharacters(in: .whitespaces).isEmpty, !fixture {
            page.displayName = NSFullUserName()
        }
        #endif
        requestPage = page
        save()
    }

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
        RequestPageCoordinator(engine: engine, client: Self.client, tokens: KeychainTokenStore())
    }

    /// Production, unless a debug build in the simulator was launched with
    /// `-AskWhenService http://localhost:8080` — how the whole loop is driven
    /// against a local service with nothing mocked. Never a release path:
    /// the argument is read only under both gates.
    static var client: AskwhenClient {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-AskWhenService"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
            return AskwhenClient(baseURL: url, appKey: appKey)
        }
        #endif
        return AskwhenClient(appKey: appKey)
    }

    /// The build's key for `POST /v1/subdomains/{label}/hold`, written into the
    /// bundle by `release.yml` from the `AW_HOLD_KEY` secret.
    ///
    /// Nil in a local build and in CI, and deliberately so: everything except
    /// reserving a name works without it, so nobody has to hold a production
    /// credential to run the app. See `AskwhenClient.appKey` for what this is
    /// and is not — it is a floor, not a secret, and `Info.plist` is an honest
    /// place to keep something anyone with the app can read anyway.
    static var appKey: String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "AWHoldKey") as? String,
              !v.isEmpty, !v.hasPrefix("$(") else { return nil }
        return v
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
