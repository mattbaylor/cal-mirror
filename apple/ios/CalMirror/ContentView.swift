import SwiftUI
import CalMirrorKit

struct ContentView: View {
    @EnvironmentObject var model: Store
    @Environment(\.scenePhase) private var phase
    /// The explainer is a first-run sheet presented from the row, not a
    /// screen on the stack (native.md, §1); Continue on it dismisses the
    /// sheet and pushes the setup at its first real step.
    @State private var showingExplainer = false
    @State private var pushingSetup = false
    /// The "Send times" line, recomputed after every sync. Local: the
    /// deriver against this device's calendars, no service.
    @State private var sendTimes: String?

    var body: some View {
        #if DEBUG
        // Screenshot mode: open straight at one screen rather than automating
        // taps to reach it. RequestPageSetupView already takes a starting
        // step, so this only says which from outside. Gated to the simulator
        // and to an explicit launch argument inside DebugSeed.
        if let step = DebugSeed.startStep {
            NavigationStack {
                if step == .explainer {
                    // As the owner meets it: a sheet over the app's root.
                    mainListBody
                        .sheet(isPresented: .constant(true)) { explainerSheet }
                } else {
                    RequestPageSetupView(start: step, page: model.config.requestPage)
                }
            }
            .environmentObject(model)
            .task { await DebugSeed.apply(to: model) }
            .sheet(item: $model.conflict) { conflict in
                // Accept and Decline are inert here: the request is invented,
                // and either would call the service about it. Leaving it is
                // real, so a hand walk through this mode is not stuck on it.
                RequestConflictSheet(conflict: conflict,
                                     onDecline: {}, onAcceptAnyway: {},
                                     onLater: { model.conflict = nil })
            }
            .task { if DebugSeed.wantsConflict { model.conflict = DebugSeed.sampleConflict(model.zone) } }
        } else {
            // The seed without a screen: the app's own root, with the synthetic
            // owner's calendar and — with -AskWhenRequest — a request waiting
            // in the queue, so Accept and Decline can be walked where they
            // actually live.
            mainList.task { await DebugSeed.apply(to: model) }
        }
        #else
        mainList
        #endif
    }

    private var mainList: some View {
        NavigationStack { mainListBody }
        .sheet(item: $model.conflict) { conflict in
            RequestConflictSheet(
                conflict: conflict,
                onDecline: { Task { await model.decline(conflict.request) } },
                onAcceptAnyway: { Task { await model.acceptAnyway(conflict.request) } },
                onLater: { model.conflict = nil })
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background {
                BackgroundSync.schedule(after: TimeInterval(model.config.intervalSeconds))
            }
            // On open, alongside the sync — the reliable path on iOS, since
            // background refresh is opportunistic and promising better would
            // be promising something the platform will not keep.
            if newPhase == .active { Task { await model.collectRequests() } }
        }
    }

    private var explainerSheet: some View {
        RequestPageExplainer(
            onContinue: { showingExplainer = false; pushingSetup = true },
            onDismiss: { showingExplainer = false })
    }

    private var mainListBody: some View {
            List {
                Section {
                    if !model.access {
                        Label("Grant Calendar access to enable syncing", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Text(lastSyncText).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if model.syncing { ProgressView() }
                    }
                }
                if model.config.mirrors.isEmpty {
                    Text("No mirrors yet. Tap + to add one.").foregroundStyle(.secondary)
                }
                // Grouped by DESTINATION, because that's the structure a real
                // config has: several sources feeding one shared calendar. It
                // also frees the row's subtitle — with the destination in the
                // header, each row need only name its source, which is what
                // fits on a phone.
                ForEach(destinationGroups, id: \.name) { group in
                    Section("\(group.name) · \(group.indices.count)") {
                        ForEach(group.indices, id: \.self) { i in
                            NavigationLink {
                                MirrorEditView(mirror: $model.config.mirrors[i])
                            } label: {
                                MirrorRow(mirror: model.config.mirrors[i],
                                          status: model.statuses[model.config.mirrors[i].id],
                                          paused: model.config.paused)
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { group.indices[$0] }
                                .map { model.config.mirrors[$0].id }
                                .forEach(model.delete(id:))
                        }
                    }
                }
                // Below the mirrors and above the sync settings: this is a
                // second thing the app does, not a setting of the first. Off
                // by default, and drawing it costs no network.
                // Requests waiting, above the setup row: an unanswered
                // request is the only thing in this app somebody else is
                // waiting on, so it outranks everything else on the screen.
                if !model.pendingRequests.isEmpty {
                    Section("Waiting for you") {
                        ForEach(model.pendingRequests) { request in
                            RequestRow(request: request, zone: model.zone,
                                       accept: { Task { await model.accept(request) } },
                                       decline: { Task { await model.decline(request) } })
                        }
                    }
                }
                // "When are you free?" answered as a message. Above the
                // request page because it is the daily-use thing; the page is
                // the upsell after it, and the link rides along once it exists.
                if model.access {
                    Section {
                        if let line = sendTimes {
                            ShareLink(item: line) {
                                Label(RequestCopy.SendTimes.row, systemImage: "text.bubble")
                            }
                        } else {
                            Label(RequestCopy.SendTimes.row, systemImage: "text.bubble")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text(sendTimes == nil
                             ? String(format: RequestCopy.SendTimes.empty, model.requestPage.policy.horizonDays)
                             : RequestCopy.SendTimes.footer)
                    }
                }
                Section {
                    if model.hasRequestPage {
                        // A page that exists, or a setup that was started:
                        // straight to it. The pitch is over.
                        NavigationLink {
                            RequestPageSetupView(page: model.config.requestPage)
                        } label: {
                            RequestPageRow(page: model.config.requestPage)
                        }
                    } else if let slug = model.recoverableSlug {
                        // The key is here, the config is not: carry on at
                        // the same address, straight to the calendars.
                        Button { model.reattachRequestPage(); pushingSetup = true } label: {
                            HStack {
                                RequestPageRow(page: nil, recoverable: slug)
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Nothing yet: the row presents the explainer as a
                        // sheet, and Continue on it pushes the setup.
                        Button { showingExplainer = true } label: {
                            HStack {
                                RequestPageRow(page: model.config.requestPage)
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                // iOS has no launchd; background refresh is the only unattended
                // path, and until now there was no way to set its interval here.
                Section("Background sync") {
                    Picker("Run no sooner than", selection: Binding(
                        get: { model.config.intervalSeconds },
                        set: { secs in
                            model.setInterval(secs)
                            BackgroundSync.schedule(after: TimeInterval(secs))
                        })) {
                        ForEach(BackgroundSync.intervalChoices, id: \.1) { name, secs in
                            Text(name).tag(secs)
                        }
                    }
                    Text("iOS decides when background refreshes actually run — this is the earliest one may start, not a guarantee. It needs Background App Refresh enabled for Calendar Mirror in Settings, and fires more reliably on a phone you use regularly. Pull to refresh any time for an immediate sync.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Calendar Mirror")
            .toolbar {
                // Both actions trailing, as symbols (native.md, §8). Pull to
                // refresh already covers the common case for sync.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await model.syncNow() } } label: {
                        Label("Sync now", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.syncing)
                    Button { model.addMirror() } label: { Label("Add mirror", systemImage: "plus") }
                }
            }
            .refreshable { await model.syncNow(); await model.collectRequests() }
            .task(id: model.lastRun) {
                guard model.access else { return }
                sendTimes = SendTimesSource.text(config: model.config, engine: model.engine, calendars: model.calendars)
            }
            .navigationDestination(isPresented: $pushingSetup) {
                RequestPageSetupView(start: .calendars, page: model.config.requestPage)
            }
            .sheet(isPresented: $showingExplainer) { explainerSheet }
    }

    /// Mirrors bucketed by destination, in first-appearance order so the list
    /// doesn't reshuffle as mirrors are edited. Values are indices into
    /// `model.config.mirrors` so each row can still bind to the real element.
    private var destinationGroups: [(name: String, indices: [Int])] {
        var order: [String] = []
        var buckets: [String: [Int]] = [:]
        for (i, m) in model.config.mirrors.enumerated() {
            let name = m.dest.title.isEmpty ? "No destination" : m.dest.title
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(i)
        }
        return order.map { (name: $0, indices: buckets[$0] ?? []) }
    }

    private var lastSyncText: String {
        guard let last = model.lastRun else { return "No sync yet" }
        return "Last sync \(last.formatted(.relative(presentation: .named)))"
    }
}

struct MirrorRow: View {
    let mirror: Mirror
    let status: MirrorResult?
    let paused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(mirror.name.isEmpty ? "Untitled" : mirror.name)
                Text(orDash(mirror.source.title))
                    .font(.caption).foregroundStyle(.secondary)
                // Only what makes THIS mirror unusual. An ordinary
                // copy-everything mirror shows nothing here, so the ones
                // carrying a projection or a filter stand out in a long list.
                // Secondary, not tinted: blue text in a row reads as a link,
                // and this is not one.
                if let delta = MirrorSummary.delta(mirror) {
                    Text(delta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let s = status, s.error == nil {
                Text("\(s.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func orDash(_ s: String) -> String { s.isEmpty ? "—" : s }

    private var icon: String {
        if paused { return "pause.circle" }
        if !mirror.enabled { return "minus.circle" }
        guard let s = status else { return "circle.dashed" }
        if let e = s.error, !e.isEmpty { return "xmark.octagon.fill" }
        return s.ok ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }
    private var color: Color {
        if paused || !mirror.enabled { return .secondary }
        guard let s = status else { return .secondary }
        return (s.error == nil && s.ok) ? .green : .red
    }
}
