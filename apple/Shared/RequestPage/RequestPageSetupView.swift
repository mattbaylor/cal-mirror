import SwiftUI
import CalMirrorKit

/// The setup flow's container. Sequences the screens `decisions.md` settled on
/// 15 September: local work first, the offer last.
///
/// ```
/// 2 explainer → 3 calendars → 4 display → 5 policy → 6 preview → 7 offer → 8 sheet
///                                                                 ^
///                                       the first network request of the app's life
/// ```
///
/// Steps 4 to 8 are not built yet; `Step` names them so the flow's shape is
/// visible in one place rather than inferred from a pile of navigation links,
/// and so adding one is an enum case rather than a re-plumb.
struct RequestPageSetupView: View {
    @EnvironmentObject var model: Store
    @State private var step: Step = .explainer

    enum Step: Int, CaseIterable {
        case explainer = 2, calendars, display, policy, preview, offer

        var title: String {
            switch self {
            case .explainer: return "Request page"
            case .calendars: return "Which calendars"
            case .display:   return "Your page"
            case .policy:    return "Your day"
            case .preview:   return "What people see"
            case .offer:     return "Publishing"
            }
        }
    }

    var body: some View {
        content
            .navigationTitle(step.title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .explainer:
            RequestPageExplainer { step = .calendars }
        case .calendars:
            Form {
                RequestCalendarFields(page: model.requestPageBinding,
                                      calendars: model.calendars,
                                      onChange: { model.save() })
                next(.display)
            }
            .formStyle(.grouped)
        case .display:
            Form {
                RequestDisplayFields(page: model.requestPageBinding,
                                     onChange: { model.save() })
                next(.policy)
            }
            .formStyle(.grouped)
        case .policy:
            Form {
                RequestPolicyFields(policy: model.requestPageBinding.policy,
                                    onChange: { model.save() })
                next(.preview)
            }
            .formStyle(.grouped)
        case .preview:
            Form {
                RequestPreview(page: model.requestPage, busy: model.busySource)
                next(.offer)
            }
            .formStyle(.grouped)
        case .offer:
            // The next tranche, and the one screen in this flow permitted to
            // touch the network. An honest placeholder rather than a plausible
            // empty screen, which would get reviewed as if it were real.
            ContentUnavailableView("Not built yet",
                                   systemImage: "hammer",
                                   description: Text("Step \(step.rawValue) — \(step.title)."))
        }
    }

    /// Deliberately never disabled. Each screen says what is still missing
    /// where the gap is, and `isReady` refuses to publish without it — a dead
    /// button with no explanation attached is the worse of the two, and every
    /// step stays reachable from the row afterwards.
    private func next(_ to: Step) -> some View {
        Section {
            Button(to == .offer ? "See what it costs" : "Continue") { step = to }
        }
    }
}
