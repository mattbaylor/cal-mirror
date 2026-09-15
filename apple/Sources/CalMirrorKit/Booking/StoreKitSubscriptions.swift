import Foundation
import StoreKit

/// The real subscription store: StoreKit 2.
///
/// Four calls and a stream, and nothing else of StoreKit leaks out — the UI
/// sees `SubscriptionOffer` and `SubscriptionState`. Verification is
/// StoreKit's own (`VerificationResult.verified`), which checks Apple's
/// signature on the device; the service checks it again, independently,
/// when the JWS is presented to `POST /v1/pages`. Two checks by two parties
/// against the same signature, neither trusting the other.
///
/// Nothing here runs until called. `offers()` is the first network request
/// the app ever makes, and it happens when the owner opens the AskWhen.me
/// setup — never at launch (decisions.md: opt-in changes nothing until
/// chosen).
public final class StoreKitSubscriptions: SubscriptionStore, @unchecked Sendable {
    public init() {}

    public func offers() async throws -> [SubscriptionOffer] {
        let products = try await Product.products(for: AskWhenTier.allCases.map(\.rawValue))
        var out: [SubscriptionOffer] = []
        for p in products {
            guard let tier = AskWhenTier(rawValue: p.id) else { continue }
            var trial: String?
            if let intro = p.subscription?.introductoryOffer, intro.paymentMode == .freeTrial,
               await p.subscription?.isEligibleForIntroOffer == true {
                trial = Self.describe(intro.period) + " free"
            }
            out.append(SubscriptionOffer(tier: tier, displayName: p.displayName, description: p.description,
                                         displayPrice: p.displayPrice, trial: trial))
        }
        return out.sorted { $0.tier.rank < $1.tier.rank }
    }

    public func purchase(_ tier: AskWhenTier) async throws -> PurchaseOutcome {
        guard let product = try await Product.products(for: [tier.rawValue]).first else {
            throw SubscriptionError.productUnavailable
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw SubscriptionError.unverified
            }
            await transaction.finish()
            return .purchased(Self.state(for: transaction, jws: verification.jwsRepresentation))
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            return .pending
        }
    }

    public func current() async -> SubscriptionState {
        // The highest-ranked live entitlement wins: after an upgrade both may
        // be present until the old period ends.
        var best: SubscriptionState = .none
        var bestRank = -1
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, let tier = AskWhenTier(rawValue: t.productID) else { continue }
            let s = Self.state(for: t, jws: result.jwsRepresentation)
            if s.isActive, tier.rank > bestRank {
                best = s
                bestRank = tier.rank
            } else if !best.isActive, case .none = best {
                best = s
            }
        }
        if case .none = best {
            // Nothing live. Was there ever anything? The latest transaction
            // for any of our products says expired or revoked.
            for tier in AskWhenTier.allCases {
                if let latest = await Transaction.latest(for: tier.rawValue), case .verified(let t) = latest {
                    return Self.state(for: t, jws: latest.jwsRepresentation)
                }
            }
        }
        return best
    }

    public func restore() async throws -> SubscriptionState {
        try await AppStore.sync()
        return await current()
    }

    public func updates() -> AsyncStream<SubscriptionState> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard case .verified(let t) = result, AskWhenTier(rawValue: t.productID) != nil else { continue }
                    await t.finish()
                    continuation.yield(Self.state(for: t, jws: result.jwsRepresentation))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: -

    static func state(for t: Transaction, jws: String) -> SubscriptionState {
        guard let tier = AskWhenTier(rawValue: t.productID) else { return .none }
        if t.revocationDate != nil { return .revoked(tier: tier) }
        if let expires = t.expirationDate {
            if expires > Date() { return .active(tier: tier, expires: expires, transaction: jws) }
            return .expired(tier: tier, at: expires)
        }
        // A subscription transaction always carries an expiry; treat its
        // absence as live rather than refuse a paying customer.
        return .active(tier: tier, expires: .distantFuture, transaction: jws)
    }

    static func describe(_ period: Product.SubscriptionPeriod) -> String {
        let n = period.value
        switch period.unit {
        case .day: return n == 1 ? "1 day" : "\(n) days"
        case .week: return n == 1 ? "1 week" : "\(n) weeks"
        case .month: return n == 1 ? "1 month" : "\(n) months"
        case .year: return n == 1 ? "1 year" : "\(n) years"
        @unknown default: return "\(n)"
        }
    }
}

public enum SubscriptionError: Error, Equatable, Sendable {
    /// App Store Connect has no such product for this app, or the store is
    /// unreachable. The sheet cannot be shown.
    case productUnavailable
    /// StoreKit could not verify Apple's signature on the transaction. Do not
    /// treat as purchased.
    case unverified
}
