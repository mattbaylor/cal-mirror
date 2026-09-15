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
    @State private var step: Step

    /// An owner returning to a page that exists lands on it, not on the
    /// explainer — the pitch is over, and re-reading it is not what they came
    /// for. A page that was configured but never published resumes where the
    /// flow left off.
    init(start: Step? = nil, page: RequestPageConfig? = nil) {
        _step = State(initialValue: start ?? (page?.slug.isEmpty == false ? .live : .explainer))
    }

    enum Step: Int, CaseIterable {
        case explainer = 2, calendars, display, policy, preview, offer, live

        var title: String {
            switch self {
            case .explainer: return "Request page"
            case .calendars: return "Which calendars"
            case .display:   return "Your page"
            case .policy:    return "Your day"
            case .preview:   return "What people see"
            case .offer:     return "Publishing"
            case .live:      return "Your page"
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
            Form {
                RequestOfferView(page: model.requestPageBinding,
                                 subscriptions: model.subscriptions,
                                 createPage: { await model.createRequestPage(transaction: $0) },
                                 onPublished: { step = .live })
            }
            .formStyle(.grouped)
        case .live:
            Form {
                // Above everything, when it applies. An owner whose page has
                // stopped taking requests is not reading this screen to copy
                // their link — they are reading it to find out what happened.
                if let lapse = model.lapse {
                    RequestLapseView(state: lapse) { step = .offer }
                }
                if lapseIsTerminal {
                    // Nothing below applies to a page that no longer exists,
                    // and a copy button for a dead link is a trap.
                    EmptyView()
                } else {
                    RequestLiveView(page: model.requestPageBinding, onChange: { model.save() })
                    RequestDomainsView(
                        page: model.requestPage,
                        tier: model.subscriptionState.tier,
                        domains: model.claimedDomains,
                        busy: model.domainsBusy,
                        error: model.domainError,
                        onClaim: { host in Task { await model.claimDomain(host) } },
                        onRelease: { host in Task { await model.releaseDomain(host) } },
                        onCheck: { Task { await model.refreshDomains() } },
                        onUpgrade: { tier in Task { await model.upgrade(to: tier) } })
                }
            }
            .formStyle(.grouped)
            .task {
                await model.refreshSubscription()
                // Only once there is a live page: a lapsed or deleted one has
                // no addresses to list, and asking would be a network request
                // on behalf of something that no longer exists.
                if model.lapse == nil { await model.refreshDomains() }
            }
        }
    }

    /// Deliberately never disabled. Each screen says what is still missing
    /// where the gap is, and `isReady` refuses to publish without it — a dead
    /// button with no explanation attached is the worse of the two, and every
    /// step stays reachable from the row afterwards.
    /// Revoked or deleted: there is no page left to manage, only to explain.
    private var lapseIsTerminal: Bool {
        model.lapse == .gone || model.lapse == .revoked
    }

    private func next(_ to: Step) -> some View {
        Section {
            Button(to == .offer ? "See what it costs" : "Continue") { step = to }
        }
    }
}
