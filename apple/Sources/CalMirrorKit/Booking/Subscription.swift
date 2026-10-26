import Foundation

/// The two paid AskWhen.me subscriptions, as App Store Connect knows them
/// (`design/billing.md`, group 22387296). What each buys mirrors
/// `internal/api/tier.go` on the service — the service enforces, this only
/// describes, and `cmk-check` asserts the two agree with `AskWhen.storekit`.
///
/// The Request Page is not a tier here: since 26 Oct 2026 it is free to
/// anyone who bought Calendar Mirror, claimed with the app transaction
/// (`SubscriptionStore.appTransaction()`), and not an App Store product.
public enum AskWhenTier: String, CaseIterable, Sendable, Codable {
    case subdomain = "me.askwhen.subdomain.annual"
    case domain = "me.askwhen.domain.annual"

    public var pages: Int { 5 }
    public var includesSubdomain: Bool { true }
    public var includesCustomDomain: Bool { self == .domain }
    /// Neither paid tier has a trial: the free page is how AskWhen.me is
    /// tried (decisions.md, 26 Oct 2026).
    public var hasTrial: Bool { false }

    /// Higher is more. The order App Store Connect ranks them in.
    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// The App Store Connect subscription group all three belong to. Handed to
    /// StoreKit's manage sheet so it opens on AskWhen.me rather than on a list
    /// of every subscription the customer has. `cmk-check` asserts it matches
    /// the group in `AskWhen.storekit`.
    public static let subscriptionGroupID = "22387296"
}

/// One subscription as it can be offered: what the sheet should say, with
/// Apple's localized price. Never hardcode a price — it comes from Apple,
/// in the customer's storefront and currency.
public struct SubscriptionOffer: Equatable, Sendable {
    public let tier: AskWhenTier
    public let displayName: String
    public let description: String
    /// "$19.99", "€21.99" — Apple's string for the storefront.
    public let displayPrice: String
    /// "3 months free", or nil. Present only when App Store Connect has an
    /// introductory offer on the product and this customer is eligible. No
    /// tier carries one today; the field stays so a future offer shows
    /// without a code change.
    public let trial: String?

    public init(tier: AskWhenTier, displayName: String, description: String, displayPrice: String, trial: String?) {
        self.tier = tier; self.displayName = displayName; self.description = description
        self.displayPrice = displayPrice; self.trial = trial
    }
}

/// What the customer currently owns.
public enum SubscriptionState: Equatable, Sendable {
    /// Never subscribed, or Apple has no record on this device.
    case none
    /// In a paid or trial period. `transaction` is the signed JWS the service
    /// verifies — `Transaction.jwsRepresentation` — and is the one thing
    /// `POST /v1/pages` needs.
    case active(tier: AskWhenTier, expires: Date, transaction: String)
    /// Was subscribed; the period ended. The page is in, or past, its grace.
    case expired(tier: AskWhenTier, at: Date)
    /// Refunded or revoked by Apple. No grace.
    case revoked(tier: AskWhenTier)

    public var tier: AskWhenTier? {
        switch self {
        case .none: return nil
        case .active(let t, _, _), .expired(let t, _), .revoked(let t): return t
        }
    }

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

public enum PurchaseOutcome: Equatable, Sendable {
    case purchased(SubscriptionState)
    /// The customer dismissed the sheet. Not an error.
    case cancelled
    /// Ask to Buy, or a payment that needs approval elsewhere. Apple will
    /// deliver the transaction later through `updates`.
    case pending
}

/// The subscription, behind a protocol so the UI is built against
/// `FakeSubscriptions` in previews and `cmk-check`, and against StoreKit in
/// the app. Nothing here is called until the owner opens the AskWhen.me
/// setup: loading products is a network request to Apple, and the app makes
/// none before the owner opts in (decisions.md).
public protocol SubscriptionStore: Sendable {
    /// The offers, with Apple's prices. Network.
    func offers() async throws -> [SubscriptionOffer]
    /// Apple's signed proof that this Apple Account has Calendar Mirror —
    /// `AppTransaction.shared`'s jwsRepresentation — which is what the free
    /// Request Page is claimed with. May be a network request; called only
    /// when the owner taps Turn on.
    func appTransaction() async throws -> String
    /// Present Apple's purchase sheet for a tier.
    func purchase(_ tier: AskWhenTier) async throws -> PurchaseOutcome
    /// What is owned now, from the device's own StoreKit cache. No network.
    func current() async -> SubscriptionState
    /// "Restore Purchases" — Apple requires the button; this is what it does.
    func restore() async throws -> SubscriptionState
    /// Renewals, upgrades and refunds as they arrive while the app runs.
    func updates() -> AsyncStream<SubscriptionState>
}

/// A subscription store for previews, the gallery, and cmk-check. Scripted:
/// set `state` and `offersToReturn`, and `purchase` flips to active.
public final class FakeSubscriptions: SubscriptionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SubscriptionState
    private var continuations: [AsyncStream<SubscriptionState>.Continuation] = []
    public var offersToReturn: [SubscriptionOffer]
    public var purchaseOutcome: PurchaseOutcome?
    public private(set) var offersFetched = 0

    public init(state: SubscriptionState = .none, offers: [SubscriptionOffer]? = nil) {
        self.state = state
        self.offersToReturn = offers ?? [
            SubscriptionOffer(tier: .subdomain, displayName: "AskWhen.me Custom Subdomain",
                              description: "Your own name.askwhen.me, and more than one page.",
                              displayPrice: "$19.99", trial: nil),
            SubscriptionOffer(tier: .domain, displayName: "AskWhen.me Custom Domain",
                              description: "Your page on your own domain, and several pages.",
                              displayPrice: "$34.99", trial: nil),
        ]
    }

    public func offers() async throws -> [SubscriptionOffer] {
        synced { offersFetched += 1; return offersToReturn }
    }

    /// Nil makes `appTransaction()` throw, as StoreKit does for a build
    /// that did not come from the App Store and has no app transaction.
    public var appTransactionToReturn: String? = "fake.app.jws"

    public func appTransaction() async throws -> String {
        guard let jws = synced({ appTransactionToReturn }) else { throw SubscriptionError.unverified }
        return jws
    }

    public func purchase(_ tier: AskWhenTier) async throws -> PurchaseOutcome {
        if let scripted = purchaseOutcome { return scripted }
        let next = SubscriptionState.active(tier: tier, expires: Date().addingTimeInterval(365 * 86400),
                                            transaction: "fake.jws.\(tier.rawValue)")
        set(next)
        return .purchased(next)
    }

    public func current() async -> SubscriptionState {
        synced { state }
    }

    public func restore() async throws -> SubscriptionState { await current() }

    public func updates() -> AsyncStream<SubscriptionState> {
        AsyncStream { continuation in
            synced { continuations.append(continuation) }
        }
    }

    // A synchronous critical section, so the async methods above never hold
    // the lock across a suspension point.
    private func synced<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Simulate Apple: a renewal, an expiry, a refund arriving.
    public func set(_ next: SubscriptionState) {
        lock.lock()
        state = next
        let listeners = continuations
        lock.unlock()
        for c in listeners { c.yield(next) }
    }
}
