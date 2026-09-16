import SwiftUI
import CalMirrorKit

/// The setup flow's container. Local work first, the offer last — and, since
/// 16 September, zero decisions before the preview (`decisions.md`, *Setup
/// with zero decisions*): the explainer's Continue infers the calendars and
/// the policy, and the first screen is the owner's own week.
///
/// ```
/// 2 explainer → (infer) → 6 preview ──→ 7 offer → 8 sheet → 9 live
///                            │  Adjust     ^
///                            ├→ 3 calendars   the first network request of the app's life
///                            ├→ 4 display
///                            └→ 5 policy
/// ```
///
/// `Step` still names every screen so the shape is visible in one place;
/// calendars, display and policy are pushed from the preview's *Adjust*
/// rows now, and are not steps in a sequence.
struct RequestPageSetupView: View {
    @EnvironmentObject var model: Store
    @State private var step: Step

    /// An owner returning to a page that exists lands on it, not on the
    /// explainer — the pitch is over, and re-reading it is not what they came
    /// for. A page that was configured but never published resumes where the
    /// flow left off.
    init(start: Step? = nil, page: RequestPageConfig? = nil) {
        _step = State(initialValue: start ?? Self.resume(for: page))
    }

    /// Where an owner lands. A page with an address and its local half —
    /// calendars and a name — is live (on or off; the live page is where it
    /// is switched). A page with an address and no local half was carried
    /// over through iCloud Keychain, and resumes at the calendars until it
    /// can publish again. A page with no address resumes where setup left
    /// off, and no page at all gets the explainer.
    static func resume(for page: RequestPageConfig?) -> Step {
        guard let page else { return .explainer }
        if !page.slug.isEmpty, page.requestCalendar != nil, !page.displayName.isEmpty { return .live }
        return .preview
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
            .toolbar {
                // Sharing is the system's sheet, not a Copy button of our own:
                // it covers copy, Messages, Mail and AirDrop, and it is where
                // an owner on either platform expects to find it.
                if step == .live, let url = liveURL {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url)
                    }
                }
            }
    }

    private var liveURL: URL? {
        let page = model.requestPage
        guard !page.slug.isEmpty, !lapseIsTerminal else { return nil }
        return URL(string: "https://askwhen.me/\(page.slug)")
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .explainer:
            // On the Mac the setup is already a sheet, so the explainer is its
            // first page and Done in the toolbar is the way out. On iOS the
            // row presents the explainer as its own sheet and pushes the
            // setup at `.calendars`, so this case is only reached from the
            // screenshot harness there.
            RequestPageExplainer(onContinue: { model.inferRequestPage(); step = .preview })
        // The three adjust screens. Pushed from the preview, so the way out
        // is Back; started directly (the screenshot harness) they stand alone.
        case .calendars:
            calendarsForm
        case .display:
            displayForm
        case .policy:
            policyForm
        case .preview:
            Form {
                // The one field zero-decision setup cannot fill on the phone.
                // Empty here means the offer cannot be published to, and the
                // warning says so before the owner reaches it.
                Section {
                    TextField(RequestCopy.Display.nameTitle,
                              text: model.requestPageBinding.displayName,
                              prompt: Text(RequestCopy.Display.namePlaceholder))
                    if model.requestPage.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label(RequestCopy.Display.nameMissing, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text(RequestCopy.Display.pageFooter)
                }
                RequestPreview(page: model.requestPage, busy: model.busySource)
                Section {
                    NavigationLink { calendarsForm.navigationTitle(Step.calendars.title) } label: {
                        adjustRow(RequestCopy.Preview.adjustCalendars, detail: calendarsSummary)
                    }
                    NavigationLink { displayForm.navigationTitle(Step.display.title) } label: {
                        adjustRow(RequestCopy.Preview.adjustPage, detail: model.requestPage.meetingTitle)
                    }
                    NavigationLink { policyForm.navigationTitle(Step.policy.title) } label: {
                        adjustRow(RequestCopy.Preview.adjustDay, detail: daySummary)
                    }
                } header: {
                    Text(RequestCopy.Preview.adjustHeader)
                } footer: {
                    Text(RequestCopy.Preview.adjustFooter)
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom) { next(.offer) }
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

    private var calendarsForm: some View {
        Form {
            RequestCalendarFields(page: model.requestPageBinding, calendars: model.calendars,
                                  onChange: { model.save() })
        }
        .formStyle(.grouped)
    }

    private var displayForm: some View {
        Form {
            RequestDisplayFields(page: model.requestPageBinding, onChange: { model.save() })
        }
        .formStyle(.grouped)
    }

    private var policyForm: some View {
        Form {
            RequestPolicyFields(policy: model.requestPageBinding.policy, onChange: { model.save() })
        }
        .formStyle(.grouped)
    }

    private func adjustRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// "3 calendars block · accepted requests go to Personal", or the warning
    /// when nothing on the device can be written to.
    private var calendarsSummary: String {
        let page = model.requestPage
        guard let receiver = page.requestCalendar else { return RequestCopy.Preview.noReceiver }
        let n = page.blocking.count
        return n == 1 ? String(format: RequestCopy.Preview.blocksOne, receiver.title)
                      : String(format: RequestCopy.Preview.blocks, n, receiver.title)
    }

    /// "9:00 AM–5:00 PM · Mon–Fri · 30 min", from the policy as it stands.
    private var daySummary: String {
        let p = model.requestPage.policy
        let days = RequestPolicy.Weekday.allCases.filter { p.weekdays.contains($0) }
        let dayText: String
        if days.count == 7 { dayText = "every day" }
        else if days == [.mon, .tue, .wed, .thu, .fri] { dayText = "Mon–Fri" }
        else { dayText = days.map { String(describing: $0).capitalized }.joined(separator: " ") }
        return "\(clock(p.day.starts))–\(clock(p.day.ends)) · \(dayText) · \(p.slotMinutes) min"
    }

    private func clock(_ hhmm: String) -> String {
        guard let mins = RequestPolicy.minutesPastMidnight(hhmm) else { return hhmm }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        let d = Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(mins) * 60)
        return f.string(from: d)
    }

    /// The primary action, pinned to the bottom and the only prominent
    /// control on the screen (`native.md`, section 4). A row in the list was
    /// where Apple never puts it.
    private func next(_ to: Step) -> some View {
        Button { step = to } label: {
            Text(to == .offer ? "See what it costs" : "Continue").frame(maxWidth: .infinity)
        }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
    }
}
