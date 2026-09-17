import SwiftUI
import CalMirrorKit

/// What a lapsed owner sees — `decisions.md`, "Lapse — 7-day grace, then
/// delete."
///
/// Three states, and they are genuinely different, so they get different words
/// rather than one message with a variable in it:
///
/// - **Grace.** The subscription ended. The page is still there and still says
///   *not currently taking requests* — the same line it shows when the
///   publisher has been offline a while, so a visitor learns nothing about the
///   owner's billing. Renewing inside the grace brings the same page back at
///   the same address, which is the fact that decides whether someone renews.
/// - **Revoked.** Apple reversed the purchase. No grace, because there was no
///   sale.
/// - **Gone.** The grace ran out and the page was deleted. Nothing to restore.
///
/// The sentence that matters in all three is the same one: **the calendar is
/// untouched.** Every request already accepted is an ordinary event that never
/// depended on the page. An owner reading this is working out what they have
/// lost, and the honest answer is "less than you think".
struct RequestLapseView: View {
    let state: LapseState
    let onRenew: () -> Void

    enum LapseState: Equatable {
        /// Days remaining, already clamped to at least zero by the caller.
        case grace(daysLeft: Int)
        case revoked
        case gone
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label(heading, systemImage: symbol)
                    .font(.headline)
                    // Both branches qualified: .secondary is a
                    // HierarchicalShapeStyle and .orange is a Color, and a
                    // ternary needs one type. Deleted is past tense and reads
                    // quieter; the other two still want attention.
                    .foregroundStyle(state == .gone ? Color.secondary : Color.orange)
                Text(explanation).fixedSize(horizontal: false, vertical: true)
                if case .grace(let days) = state {
                    Text(countdown(days)).font(.callout.weight(.semibold))
                    Text(RequestCopy.Lapse.graceWhatGoes)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(RequestCopy.Lapse.graceFix)
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if state == .gone {
                    Text(RequestCopy.Lapse.goneCalendar)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(state == .gone ? RequestCopy.Lapse.startAgain : RequestCopy.Lapse.renew,
                   action: onRenew)
                .askWhenProminent(.regular)
        }
    }

    /// Singular gets its own string rather than "1 days" or "1 day(s)". It is
    /// the last day of the grace, which is the one an owner is most likely to
    /// be reading.
    private func countdown(_ days: Int) -> String {
        days == 1 ? RequestCopy.Lapse.graceCountOne
                  : String(format: RequestCopy.Lapse.graceCountMany, days)
    }

    private var heading: String {
        switch state {
        case .grace:   return RequestCopy.Lapse.graceHeading
        case .revoked: return RequestCopy.Lapse.revokedHeading
        case .gone:    return RequestCopy.Lapse.goneHeading
        }
    }

    private var explanation: String {
        switch state {
        case .grace:   return RequestCopy.Lapse.graceBody
        case .revoked: return RequestCopy.Lapse.revokedBody
        case .gone:    return RequestCopy.Lapse.goneBody
        }
    }

    private var symbol: String {
        switch state {
        case .grace:   return "clock.badge.exclamationmark"
        case .revoked: return "arrow.uturn.backward.circle"
        case .gone:    return "trash"
        }
    }
}

extension RequestLapseView.LapseState {
    /// The grace is seven days from expiry, and the service is the authority —
    /// it deletes on its own schedule from App Store Server Notifications, and
    /// this device may have been asleep through the whole thing. So a device
    /// that computes a positive countdown against a page the service has
    /// already removed is wrong, and finding the slug gone is what settles it.
    static func from(_ state: SubscriptionState, pageExists: Bool, now: Date = Date()) -> Self? {
        switch state {
        case .none, .active:
            return nil
        case .revoked:
            return pageExists ? .revoked : .gone
        case .expired(_, let at):
            guard pageExists else { return .gone }
            let deadline = at.addingTimeInterval(7 * 86400)
            let days = Int(ceil(deadline.timeIntervalSince(now) / 86400))
            return days > 0 ? .grace(daysLeft: days) : .gone
        }
    }
}
