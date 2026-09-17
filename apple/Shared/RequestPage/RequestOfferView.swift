import SwiftUI
import CalMirrorKit

/// Screens 7 and 8 — the offer, Apple's sheet, and the page that exists
/// afterwards.
///
/// **This is the screen the privacy promise is measured against.** Everything
/// before it is local; `offers()` is the app's first network request of any
/// kind, and it is made here because the owner asked what this costs
/// (`decisions.md`, "The product load happens on the offer screen"). Screen 2's
/// footnote promises exactly that, so if this view ever loads products in
/// `init`, or a parent prefetches them, the promise is broken and the screen
/// still looks fine — which is why the load is tied to `task` on the *offer*
/// phase rather than to the view appearing.
///
/// The trial is never hardcoded. `SubscriptionOffer.trial` is nil for a
/// customer who has used their one introductory offer, so a returning owner is
/// told the price plainly instead of being promised something Apple will not
/// give them.
struct RequestOfferView: View {
    @Binding var page: RequestPageConfig
    let subscriptions: SubscriptionStore
    /// Publishing is the caller's — this view knows how to buy, not how to
    /// talk to askwhen.me, and the coordinator holds the token store.
    let createPage: (_ transaction: String) async -> Result<Void, Error>
    let onPublished: () -> Void

    @State private var phase: Phase = .checking

    enum Phase: Equatable {
        /// `current()` reads the device's StoreKit cache and makes no network
        /// request, so asking first costs nothing and spares an owner who
        /// already subscribes a price list they do not need.
        case checking
        case loading
        case offering([SubscriptionOffer])
        case failed
        case alreadySubscribed(SubscriptionState)
        case purchasing
        case cancelled([SubscriptionOffer])
        case pending
        case creating
        case createFailed(String)
        case done
    }

    var body: some View {
        Group {
            switch phase {
            case .checking, .loading:
                progress(RequestCopy.Offer.loading)
            case .offering(let offers), .cancelled(let offers):
                offerList(offers, cancelled: isCancelled)
            case .failed:
                failure(RequestCopy.Offer.failedTitle, RequestCopy.Offer.failedBody) {
                    await load()
                }
            case .alreadySubscribed(let state):
                already(state)
            case .purchasing:
                // Apple's sheet is up, or has just gone: "asking for the
                // price" is the wrong sentence under it.
                progress(RequestCopy.Offer.purchasing)
            case .pending:
                notice(RequestCopy.Offer.pendingTitle, RequestCopy.Offer.pendingBody, "clock.badge.checkmark")
            case .creating:
                progress(RequestCopy.Offer.creating)
            case .createFailed(let detail):
                failure(RequestCopy.Offer.createFailedTitle,
                        RequestCopy.Offer.createFailedBody + "\n\n" + detail) {
                    await republish()
                }
            case .done:
                Color.clear.onAppear(perform: onPublished)
            }
        }
        // Tied to the phase, not to the view: entering `.checking` is the
        // owner arriving at the price, and nothing earlier may trigger it.
        .task(id: phase == .checking) {
            guard phase == .checking else { return }
            await load()
        }
    }

    private var isCancelled: Bool {
        if case .cancelled = phase { return true }
        return false
    }

    // MARK: Screens

    private func offerList(_ offers: [SubscriptionOffer], cancelled: Bool) -> some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(RequestCopy.Offer.heading).font(.title2.weight(.semibold))
                    Text(RequestCopy.Offer.lede).fixedSize(horizontal: false, vertical: true)
                }
                if cancelled {
                    Label(RequestCopy.Offer.cancelled, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                // The privacy promise this screen is measured against, as the
                // one footer on the first group.
                Text(RequestCopy.Offer.network)
            }

            if let base = offers.first(where: { $0.tier == .page }) {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(base.displayName).font(.headline)
                        Text(base.description).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(priceLine(base)).font(.callout.weight(.medium))
                        if base.trial == nil {
                            Text(RequestCopy.Offer.noTrialNote)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button { Task { await buy(.page) } } label: {
                        Text(base.trial == nil ? RequestCopy.Offer.buyWithoutTrial
                                               : RequestCopy.Offer.buyWithTrial)
                            .frame(maxWidth: .infinity)
                    }
                    .askWhenProminent()
                } footer: {
                    Text(RequestCopy.Offer.renews)
                }
            }

            // Shown, never sold here. decisions.md: the offer screen sells the
            // Request Page trial, and these two are upgrades the owner meets
            // when they want one — a nicer address is worth nothing before
            // there is a page at it.
            Section {
                ForEach(offers.filter { $0.tier != .page }, id: \.tier) { offer in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(offer.displayName).font(.callout)
                            Spacer()
                            Text(offer.displayPrice).foregroundStyle(.secondary)
                        }
                        Text(offer.description).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(RequestCopy.Offer.upgradesHeading)
            } footer: {
                Text(RequestCopy.Offer.upgradesNote)
            }

            // Apple's guidelines require this on any subscription screen, and
            // it is the only way back for an owner who reinstalled.
            Section {
                Button(RequestCopy.Offer.restore) { Task { await restore() } }
            }
        }
    }

    private func already(_ state: SubscriptionState) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(RequestCopy.Offer.alreadyTitle).font(.headline)
                Text(RequestCopy.Offer.alreadyBody).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                guard case .active(_, _, let transaction) = state else { return }
                Task { await publish(transaction) }
            } label: {
                Text(RequestCopy.Offer.publish).frame(maxWidth: .infinity)
            }
            .askWhenProminent()
        } footer: {
            Text(RequestCopy.Offer.tokenWarning)
        }
    }

    private func progress(_ label: String) -> some View {
        Section {
            HStack(spacing: 10) { ProgressView(); Text(label).foregroundStyle(.secondary) }
        }
    }

    private func notice(_ title: String, _ body: String, _ symbol: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.headline)
                Text(body).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func failure(_ title: String, _ body: String,
                         retry: @escaping () async -> Void) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text(body).fixedSize(horizontal: false, vertical: true)
            }
            Button(RequestCopy.Offer.retry) { Task { await retry() } }
        }
    }

    /// "3 months free, then $19.99 a year." Both halves come from Apple, so
    /// the currency, the storefront rounding and the trial's own wording are
    /// whatever Apple says they are rather than what this file assumes.
    private func priceLine(_ o: SubscriptionOffer) -> String {
        if let trial = o.trial {
            return String(format: RequestCopy.Offer.trialLine, trial, o.displayPrice)
        }
        return String(format: RequestCopy.Offer.noTrialLine, o.displayPrice)
    }

    // MARK: Actions

    private func load() async {
        // Free and offline. An owner who already subscribes never sees a price
        // list, and the app never asks Apple for one it does not need.
        let state = await subscriptions.current()
        if state.isActive { phase = .alreadySubscribed(state); return }

        phase = .loading
        // Four attempts, backing off a second at a time. The first product
        // request after launch comes back empty in the simulator often enough
        // that two attempts a second apart still showed the failure screen on
        // 17 Sept, with "Try again" succeeding immediately; a transient like
        // that must not be the owner's — or a reviewer's — problem to notice.
        // Anything that fails four times is the real failure screen.
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(attempt)) }
            // StoreKit answers an unknown product id with silence, not an
            // error — an empty list, or one without the page tier — and the
            // screen that would render is a heading over nothing with no way
            // forward. Seen first in a simulator with no .storekit file
            // attached; on a device it is the App Store unreachable.
            if let offers = try? await subscriptions.offers(),
               offers.contains(where: { $0.tier == .page }) {
                phase = .offering(offers)
                return
            }
        }
        phase = .failed
    }

    private func buy(_ tier: AskWhenTier) async {
        let previous = phase
        phase = .purchasing
        do {
            switch try await subscriptions.purchase(tier) {
            case .purchased(let state):
                guard case .active(_, _, let transaction) = state else { phase = previous; return }
                await publish(transaction)
            case .cancelled:
                // Not an error and not a dead end: back to the same offers,
                // with a line saying nothing happened.
                if case .offering(let offers) = previous { phase = .cancelled(offers) }
                else { phase = previous }
            case .pending:
                phase = .pending
            }
        } catch {
            phase = .failed
        }
    }

    private func restore() async {
        phase = .loading
        let state = await (try? subscriptions.restore()) ?? .none
        if state.isActive { phase = .alreadySubscribed(state); return }
        // Nothing to restore is not a failure — reload the offers and let the
        // owner buy, rather than leaving them on a screen with no way forward.
        await load()
    }

    /// The page is created with Apple's signed transaction; the service
    /// verifies the signature itself and derives the entitlement. Only once it
    /// answers with a slug is the page turned on — `enabled` is the opt-in, and
    /// a page enabled without a slug would poll nothing forever.
    private func publish(_ transaction: String) async {
        phase = .creating
        switch await createPage(transaction) {
        case .success:
            page.enabled = true
            phase = .done
        case .failure(let error):
            lastTransaction = transaction
            phase = .createFailed(String(describing: error))
        }
    }

    @State private var lastTransaction: String?

    /// Retrying after the service failed. `create` is safe to call again — it
    /// mints a new slug only if the last attempt never produced one, and the
    /// subscription is already bought either way, so this cannot double-charge.
    private func republish() async {
        guard let t = lastTransaction else { await load(); return }
        await publish(t)
    }
}
