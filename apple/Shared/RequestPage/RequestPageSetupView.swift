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
                Section {
                    // Deliberately not disabled on an incomplete choice. The
                    // warnings in the section above say what is missing, and
                    // `isReady` refuses to publish without it — a dead button
                    // with no explanation is the worse of the two, and this
                    // screen is reachable again from the row at any time.
                    Button("Continue") { step = .display }
                }
            }
            .formStyle(.grouped)
        default:
            // Honest placeholder rather than a half-screen: these are the next
            // tranche, and a convincing-looking empty step would be the kind of
            // thing that gets reviewed as if it were real.
            ContentUnavailableView("Not built yet",
                                   systemImage: "hammer",
                                   description: Text("Step \(step.rawValue) — \(step.title)."))
        }
    }
}
