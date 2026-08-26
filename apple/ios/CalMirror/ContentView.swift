import SwiftUI
import CalMirrorKit

struct ContentView: View {
    @EnvironmentObject var model: Store
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
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
                ForEach($model.config.mirrors) { $m in
                    NavigationLink {
                        MirrorEditView(mirror: $m)
                    } label: {
                        MirrorRow(mirror: m, status: model.statuses[m.id], paused: model.config.paused)
                    }
                }
                .onDelete { offsets in
                    offsets.map { model.config.mirrors[$0].id }.forEach(model.delete(id:))
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
                    Text("iOS decides when background refreshes actually run — this is the earliest one may start, not a guarantee. It needs Background App Refresh enabled for cal-mirror in Settings, and fires more reliably on a phone you use regularly. Pull to refresh any time for an immediate sync.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("cal-mirror")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sync now") { Task { await model.syncNow() } }.disabled(model.syncing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.addMirror() } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await model.syncNow() }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background {
                BackgroundSync.schedule(after: TimeInterval(model.config.intervalSeconds))
            }
        }
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
                Text("\(orDash(mirror.source.title))  →  \(orDash(mirror.dest.title))")
                    .font(.caption).foregroundStyle(.secondary)
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
