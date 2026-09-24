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
/// The three things this screen can ask askwhen.me before anything is bought:
/// whether a name is free, to keep it for the length of a purchase, and to
/// turn that reservation into the real thing once the page exists.
///
/// Separate from the purchase on purpose. Buying the tier and getting the name
/// are two outcomes, and the owner must be able to end up with the first and
/// not the second without the screen calling that a failure — the name is
/// still claimable from the page afterwards.
struct SubdomainActions {
    let check: (_ label: String) async -> Result<AskwhenClient.SubdomainAvailability, Error>
    let hold: (_ label: String) async -> Result<AskwhenClient.SubdomainHold, Error>
    let claim: (_ host: String, _ secret: String) async -> Result<Void, Error>
}

struct RequestOfferView: View {
    @Binding var page: RequestPageConfig
    let subscriptions: SubscriptionStore
    /// Publishing is the caller's — this view knows how to buy, not how to
    /// talk to askwhen.me, and the coordinator holds the token store.
    let createPage: (_ transaction: String) async -> Result<Void, Error>
    let onPublished: () -> Void
    /// Asking for a name before paying for one. Closures rather than a
    /// protocol, because `createPage` already set that shape here and the
    /// screen should not need two ways to reach the same service.
    var names: SubdomainActions? = nil

    @State private var phase: Phase = .checking
    @State private var label = ""
    @State private var name: NameState = .unasked
    /// Survives the purchase so the claim can happen once the page exists.
    @State private var heldName: (host: String, secret: String)?

    /// What the service last said about the typed label. `.free` is the only
    /// state that changes what Subscribe does.
    enum NameState: Equatable {
        case unasked
        case checking
        case free(String)
        case refused(String)
        case failed
        /// Lost between the check and the purchase. Nothing was bought.
        case lost(String)
    }

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
        // NOT `.task(id: phase == .checking)`, however well that reads. The
        // first thing `load()` does after its opening await is set
        // `phase = .loading`, which flips a phase-derived id and makes SwiftUI
        // cancel the task doing the loading. Everything downstream then lies:
        // `Product.products` throws CancellationError into a `try?`, a
        // cancelled `Task.sleep` does not sleep, so four attempts and six
        // seconds of backoff pass in microseconds and the owner gets "Could
        // not reach the App Store" in well under a second. That shipped in 12
        // and 13, and it is why App Review could not find any of the three
        // products — including the one this screen has always sold. "Try
        // again" worked because its Task is not the view's.
        //
        // A plain `.task` keeps the promise this screen is measured against:
        // it runs when the view appears, and the view is built only at
        // `step == .offer` — the owner asking what this costs. The guard is
        // what stops a future parent from constructing it earlier.
        .task {
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

            // The Request Page trial stays the one prominent action
            // (decisions.md), but these two are buyable here as well, not only
            // from the address screen after a page exists. App Review rejected
            // 2.0 under 2.1(b) because it could not find them in the binary: a
            // product that can only be bought once another has been bought and
            // a server has answered is, to a reviewer, not there.
            Section {
                ForEach(offers.filter { $0.tier != .page }, id: \.tier) { offer in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(offer.displayName).font(.callout)
                        Text(offer.description).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // The price carries its period, as the Page tier's
                        // does: 3.1.2 wants the length of an auto-renewable
                        // subscription on the screen that sells it, and
                        // "$34.99" alone in a trailing column does not say
                        // "a year". The footer below says it again for both.
                        Text(priceLine(offer)).font(.caption.weight(.medium))
                    }
                    // The name goes with the tier that grants it, and is
                    // asked for before the money — which is the whole reason
                    // this section exists rather than only the Address screen.
                    if offer.tier == .subdomain, names != nil {
                        nameField
                    }
                    Button(RequestCopy.Offer.buyWithoutTrial) { Task { await buy(offer.tier) } }
                        .accessibilityLabel("\(RequestCopy.Offer.buyWithoutTrial), \(offer.displayName)")
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

    /// The name, asked for here rather than discovered after paying.
    ///
    /// Checking reserves nothing — an owner trying five names must not park
    /// four of them — so the reservation is taken when they tap Subscribe,
    /// which is also the only moment it is worth anything.
    @ViewBuilder private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                TextField(RequestCopy.Offer.nameField, text: $label)
                    .textFieldStyle(.roundedBorder)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .onChange(of: label) { _, _ in
                        // A name that has been edited has not been checked,
                        // and a stale tick beside a new word would be a lie.
                        name = .unasked
                    }
                Text(RequestCopy.Domains.subdomainSuffix).foregroundStyle(.secondary)
            }
            Button(RequestCopy.Offer.nameCheck) { Task { await checkName() } }
                .disabled(typedLabel.isEmpty || name == .checking)

            switch name {
            case .unasked:
                EmptyView()
            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(RequestCopy.Offer.nameChecking).font(.caption).foregroundStyle(.secondary)
                }
            case .free(let host):
                Label(String(format: RequestCopy.Offer.nameFree, host), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case .refused(let why):
                Label(why, systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed:
                Label(RequestCopy.Offer.nameFailed, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .lost(let host):
                Label(String(format: RequestCopy.Offer.nameLost, host), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(RequestCopy.Offer.nameOptional)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var typedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        // Four attempts, backing off a second at a time, because a first
        // product request can genuinely come back empty and a transient must
        // not be the owner's — or a reviewer's — problem to notice.
        //
        // The cancellation checks are not defensive clutter: without them a
        // cancelled task runs the whole loop instantly (a cancelled sleep
        // returns at once, and every `try?` swallows the CancellationError)
        // and paints the failure screen on its way out. That is precisely how
        // this screen lied for two builds. If this task is cancelled, the
        // right answer is to leave the screen as it is and say nothing.
        for attempt in 0..<4 {
            if attempt > 0 {
                do { try await Task.sleep(for: .seconds(attempt)) } catch { return }
            }
            if Task.isCancelled { return }
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
        if Task.isCancelled { return }
        phase = .failed
    }

    /// Asks, and reserves nothing. The service's own sentence is shown for a
    /// refusal it knows more about than this app does — reserved labels and
    /// malformed ones both arrive that way.
    private func checkName() async {
        guard let names, !typedLabel.isEmpty else { return }
        name = .checking
        switch await names.check(typedLabel) {
        case .success(let answer) where answer.available:
            name = .free(answer.host)
        case .success(let answer):
            if answer.reason == "invalid", let why = answer.why, !why.isEmpty {
                name = .refused(why)
            } else {
                name = .refused(String(format: RequestCopy.Offer.nameTaken,
                                       answer.host.isEmpty ? typedLabel : answer.host))
            }
        case .failure:
            // Not a dead end: the tier is still worth buying, and the name can
            // still be taken from the page afterwards.
            name = .failed
        }
    }

    private func buy(_ tier: AskWhenTier) async {
        let previous = phase

        // The reservation is taken here, between the decision and the money,
        // because Apple's sheet is the window it exists to cover. If the name
        // has gone in the meantime, nothing is bought: an owner who came for
        // dana.askwhen.me should not be charged for somebody else's.
        heldName = nil
        if tier == .subdomain, let names, case .free = name, !typedLabel.isEmpty {
            switch await names.hold(typedLabel) {
            case .success(let held):
                heldName = (held.host, held.secret)
            case .failure(AskwhenError.rejected):
                name = .lost(typedLabel + RequestCopy.Domains.subdomainSuffix)
                return
            case .failure:
                // The service could not be reached. The subscription is still
                // worth having, so carry on and let the name be taken later.
                name = .failed
            }
        }

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
            // The reservation becomes the real thing now that there is a page
            // to attach it to. A failure here is not a failed purchase and is
            // not allowed to look like one: the subscription is bought, and
            // the Address section on the next screen can still claim it.
            if let held = heldName, let names {
                if case .failure = await names.claim(held.host, held.secret) {
                    name = .refused(String(format: RequestCopy.Offer.nameClaimFailed, held.host))
                }
                heldName = nil
            }
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
