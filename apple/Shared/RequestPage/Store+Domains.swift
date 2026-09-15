import SwiftUI
import CalMirrorKit

/// Addresses and subscription state — the two things about a page that live on
/// the service rather than in `Config`, and so have to be asked for.
extension Store {

    /// Refresh the address list. Every call re-reads DNS on the service, which
    /// is why the UI's "check now" and this are the same call: there is no
    /// cheaper read that would still make progress.
    func refreshDomains() async {
        guard !requestPage.slug.isEmpty else { return }
        domainsBusy = true
        defer { domainsBusy = false }
        do {
            claimedDomains = try await requestCoordinator().domains(page: requestPage)
            domainError = nil
        } catch let e as AskwhenError {
            domainError = message(for: e)
        } catch {
            domainError = RequestCopy.Domains.failed
        }
    }

    func claimDomain(_ host: String) async {
        domainsBusy = true
        defer { domainsBusy = false }
        do {
            let claimed = try await requestCoordinator().claimDomain(host, page: requestPage)
            // Replace rather than append: claiming a host already listed is how
            // a re-check of a pending domain arrives, and two rows for one
            // hostname would be a bug the owner has to interpret.
            claimedDomains.removeAll { $0.host == claimed.host }
            claimedDomains.append(claimed)
            domainError = nil
        } catch let e as AskwhenError {
            domainError = message(for: e)
        } catch {
            domainError = RequestCopy.Domains.failed
        }
    }

    func releaseDomain(_ host: String) async {
        domainsBusy = true
        defer { domainsBusy = false }
        do {
            try await requestCoordinator().releaseDomain(host, page: requestPage)
            claimedDomains.removeAll { $0.host == host }
            domainError = nil
        } catch let e as AskwhenError {
            domainError = message(for: e)
        } catch {
            domainError = RequestCopy.Domains.failed
        }
    }

    /// The service's own words where it has any. A 409 means somebody already
    /// holds the name; a rejection carries the service's reason, and rewording
    /// it here would only make a real DNS problem harder to recognize.
    private func message(for error: AskwhenError) -> String {
        switch error {
        case .rejected(let reason): return reason.isEmpty ? RequestCopy.Domains.taken : reason
        case .notFound: return RequestCopy.Domains.taken
        default: return RequestCopy.Domains.failed
        }
    }

    // MARK: Subscription and lapse

    /// Reads the device's own StoreKit cache — no network — so it is safe to
    /// call whenever the page screen is opened.
    func refreshSubscription() async {
        subscriptionState = await subscriptions.current()
    }

    /// Nil while the subscription is healthy. `pageExists` is the device's
    /// slug: the service deletes on its own schedule from Apple's server
    /// notifications, and a device that slept through the grace would
    /// otherwise count down against a page that is already gone.
    var lapse: RequestLapseView.LapseState? {
        RequestLapseView.LapseState.from(subscriptionState,
                                         pageExists: !requestPage.slug.isEmpty)
    }

    /// Buying an upgrade from where the want appeared. Apple prorates; the
    /// device only has to notice the tier changed.
    func upgrade(to tier: AskWhenTier) async {
        guard case .purchased(let state) = (try? await subscriptions.purchase(tier)) else { return }
        subscriptionState = state
    }

    /// Keeps the tier honest while the app runs — a renewal, an upgrade bought
    /// on another device, or a refund all arrive here rather than at the next
    /// launch.
    func watchSubscription() async {
        for await state in subscriptions.updates() {
            subscriptionState = state
            // A page that has come back to life should start publishing again
            // without the owner doing anything.
            if state.isActive, requestPage.isReady { _ = try? await publishIfNeeded() }
        }
    }

    @discardableResult
    func publishIfNeeded() async throws -> PublishOutcome {
        var page = requestPage
        let outcome = try await requestCoordinator().publishIfNeeded(page: &page)
        requestPage = page
        save()
        return outcome
    }
}
