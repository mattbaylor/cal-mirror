import SwiftUI
import CalMirrorKit

// MARK: - Menu bar dropdown

/// Status, the requests that need answering, one line per mirror, and the
/// four commands. App settings live under ⌘, (`SettingsView`), and the
/// per-mirror controls live in the window — a menu-bar utility shows what is
/// happening and the one or two actions that matter (`native.md`, Mac §6).
struct MenuContent: View {
    @ObservedObject var model: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Calendar Mirror — \(model.headline)")
        // First in the menu, because somebody is waiting on it.
        if !model.pendingRequests.isEmpty {
            Divider()
            ForEach(model.pendingRequests) { request in
                Menu("\(request.name) — \(RequestNotifications.when(request.slot, in: model.zone))") {
                    if let note = request.note, !note.isEmpty { Text(note).font(.caption) }
                    Text(request.email).font(.caption)
                    Divider()
                    Button(RequestCopy.Notification.accept) { Task { await model.accept(request) } }
                    Button(RequestCopy.Notification.decline) { Task { await model.decline(request) } }
                }
            }
        }
        Divider()
        if model.config.mirrors.isEmpty { Text("No mirrors yet").font(.caption) }
        ForEach(model.config.mirrors) { m in
            Button("\(symbol(model.iconFor(m.id)))  \(m.name)\(count(m))") { openManage() }
        }
        Divider()
        Button(model.config.paused ? "Resume Syncing" : "Sync Now") {
            if model.config.paused { model.togglePause() } else { Task { await model.syncNow() } }
        }
        Button("Pause Syncing") { model.togglePause() }.disabled(model.config.paused)
        Divider()
        Button("Manage Mirrors…") { openManage() }
        Button("Settings…") {
            NSApp.setActivationPolicy(.regular)
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Calendar") { NSWorkspace.shared.open(URL(string: "ical://")!) }
        Divider()
        Button("Quit Calendar Mirror") { NSApp.terminate(nil) }
    }

    private func openManage() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "manage")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func count(_ m: Mirror) -> String {
        guard let s = model.statuses[m.id] else { return "" }
        if let e = s.error, !e.isEmpty { return "  ⚠︎" }
        return "  ·  \(s.total)"
    }

    private func symbol(_ n: String) -> String {
        switch n {
        case "checkmark.circle.fill": return "✓"
        case "exclamationmark.triangle.fill": return "⚠︎"
        case "xmark.octagon.fill": return "✗"
        case "pause.circle": return "⏸"
        case "minus.circle": return "∅"
        default: return "•"
        }
    }
}

// MARK: - Management window

/// Mirrors grouped by destination on the left, the selected mirror on the
/// right, the actions in the toolbar — the window the store screenshots
/// already showed and the standalone app already had (`native.md`, Mac §1–2).
struct ManageView: View {
    @ObservedObject var model: Store
    @State private var selection: String?
    @State private var showingSetup = false
    @FocusState private var focusedName: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(destinationGroups, id: \.name) { group in
                    Section("\(group.name)  ·  \(group.indices.count)") {
                        ForEach(group.indices, id: \.self) { i in
                            MacSidebarRow(model: model, mirror: model.config.mirrors[i])
                                .tag(model.config.mirrors[i].id)
                        }
                    }
                }
                // The request page is the last row of the sidebar: a second
                // thing the app does, listed after the mirrors, in the window
                // where the owner is already looking at their calendars.
                Section("AskWhen.me") {
                    Button { showingSetup = true } label: {
                        RequestPageRow(page: model.config.requestPage)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            if let idx = selectedIndex {
                MacMirrorDetail(model: model, m: $model.config.mirrors[idx],
                                focusedName: $focusedName, onRemove: removeSelected)
                    .id(model.config.mirrors[idx].id)
            } else {
                ContentUnavailableView("No Mirror Selected",
                                       systemImage: "arrow.left.arrow.right",
                                       description: Text("Pick a mirror on the left, or add one."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.addMirror()
                    selection = model.config.mirrors.last?.id
                    focusedName = selection
                } label: { Label("Add Mirror", systemImage: "plus") }
            }
            ToolbarItem {
                Button { Task { await model.syncNow() } } label: {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
                .disabled(model.syncing || !model.access)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { if selection == nil { selection = model.config.mirrors.first?.id } }
        .overlay(alignment: .top) {
            if !model.access {
                Text("Calendar access not granted yet — grant it in System Settings so the pickers can list your calendars.")
                    .foregroundStyle(.orange)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
            }
        }
        .sheet(isPresented: $showingSetup) {
            NavigationStack { RequestPageSetupView(page: model.config.requestPage) }
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 560)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingSetup = false }
                } }
        }
        // Drop back to a menu-bar-only app when the window closes.
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    /// Mirrors bucketed by destination, in first-appearance order, as indices
    /// into `config.mirrors` so each row still binds to the real element.
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

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return model.config.mirrors.firstIndex { $0.id == selection }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        let idx = model.config.mirrors.firstIndex { $0.id == id }
        model.delete(id: id)
        // Select the neighbor that took its place, so the detail pane isn't
        // left empty after every removal.
        let mirrors = model.config.mirrors
        if let idx { selection = mirrors.indices.contains(idx) ? mirrors[idx].id : mirrors.last?.id }
        else { selection = mirrors.first?.id }
    }
}

/// One row in the sidebar: health, name, source, and what makes this mirror
/// unusual. The destination is the section header, so the row need not
/// repeat it. Secondary, not tinted, for the summary line — blue in a row
/// reads as a link.
struct MacSidebarRow: View {
    @ObservedObject var model: Store
    let mirror: Mirror

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.iconFor(mirror.id)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(mirror.name.isEmpty ? "Untitled" : mirror.name).lineLimit(1)
                Text(mirror.source.title.isEmpty ? "— no source —" : mirror.source.title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let delta = MirrorSummary.delta(mirror) {
                    Text(delta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let s = model.statuses[mirror.id], s.error == nil {
                Text("\(s.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch model.iconFor(mirror.id) {
        case "checkmark.circle.fill": return .green
        case "exclamationmark.triangle.fill": return .orange
        case "xmark.octagon.fill": return .red
        default: return .secondary
        }
    }
}

/// One mirror's settings. The pair is always visible; everything else
/// collapses to a header line that says what it is set to. Each expanded
/// group is its own `Section`, so its rows keep their dividers and spacing
/// (`native.md`, Mac §4).
struct MacMirrorDetail: View {
    @ObservedObject var model: Store
    @Binding var m: Mirror
    @FocusState.Binding var focusedName: String?
    let onRemove: () -> Void

    @State private var showProjection = false
    @State private var showSelection = false
    @State private var showAdvanced = false

    init(model: Store, m: Binding<Mirror>, focusedName: FocusState<String?>.Binding, onRemove: @escaping () -> Void) {
        self.model = model; self._m = m; self._focusedName = focusedName; self.onRemove = onRemove
        #if DEBUG
        _showProjection = State(initialValue: MacFixture.expand == "projection")
        _showSelection = State(initialValue: MacFixture.expand == "selection")
        _showAdvanced = State(initialValue: MacFixture.expand == "advanced")
        #endif
    }

    var body: some View {
        Form {
            Section("Pair") {
                PairFields(mirror: $m, calendars: model.calendars,
                           reverseConflict: { s, d in model.reverseConflict(source: s, dest: d, excluding: m.id) },
                           onChange: { model.save() })
                Toggle("Enabled", isOn: $m.enabled).onChange(of: m.enabled) { _, _ in model.save() }
                // A failing mirror says so where it is edited, not only in
                // the menu — the red mark in the sidebar needs its sentence.
                if let e = model.statuses[m.id]?.error, !e.isEmpty {
                    Label(e, systemImage: "xmark.octagon.fill")
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            group($showProjection, title: "What crosses over", trailing: nil,
                  detail: MirrorSummary.projection(m.projection)) {
                ProjectionFields(mirror: $m, onChange: { model.save() })
            }
            group($showSelection, title: "Which events", trailing: ruleCountLabel,
                  detail: MirrorSummary.selection(m.filters, tagFilter: m.tagFilter)) {
                SelectionFields(mirror: $m, onChange: { model.save() })
            }
            group($showAdvanced, title: "Advanced", trailing: nil,
                  detail: MirrorSummary.advanced(m)) {
                AdvancedFields(mirror: $m, onChange: { model.save() })
                if let ls = m.legacyScheme {
                    Text("Migrating legacy tags (\(ls))").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Mirror", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        // Deliberately no .navigationTitle: in a split view the detail's
        // title becomes the window's, renaming "Manage Mirrors" per mirror.
    }

    /// A collapsed group is one row with its summary; an expanded one is the
    /// same row followed by its own section of controls.
    @ViewBuilder
    private func group<Content: View>(_ open: Binding<Bool>, title: String, trailing: String?,
                                      detail: String?, @ViewBuilder content: () -> Content) -> some View {
        Section {
            Button { withAnimation { open.wrappedValue.toggle() } } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                    SummaryLabel(title: title, trailing: trailing, detail: detail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        if open.wrappedValue {
            Section { content() }
        }
    }

    private var ruleCountLabel: String? {
        var n = m.filters.activeRuleCount
        if m.tagFilter?.isActive == true { n += 1 }
        guard n > 0 else { return nil }
        return n == 1 ? "1 rule" : "\(n) rules"
    }
}

/// A disclosure header that names a group and says what it is currently set
/// to, so the collapsed state still carries the answer.
struct SummaryLabel: View {
    let title: String
    let trailing: String?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title)
                if let trailing { Spacer(); Text(trailing).foregroundStyle(.secondary) }
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Settings (⌘,)

/// App settings, where the Mac keeps them. These used to be toggles in the
/// status menu (`native.md`, Mac §3).
struct SettingsView: View {
    @ObservedObject var model: Store
    private let intervals: [(String, Int)] = [("5 minutes", 300), ("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600)]

    var body: some View {
        Form {
            Section {
                Toggle("Sync when a calendar changes", isOn: Binding(
                    get: { model.config.realtime }, set: { _ in model.toggleRealtime() }))
                Picker("Otherwise, sync every", selection: Binding(
                    get: { model.config.intervalSeconds }, set: { model.setInterval($0) })) {
                    ForEach(intervals, id: \.1) { name, secs in Text(name).tag(secs) }
                }
                .disabled(model.config.realtime)
            } footer: {
                Text(model.config.realtime
                     ? (model.observing ? "Watching for changes, with a 5-minute check underneath."
                                        : "Not watching right now — using the 5-minute schedule.")
                     : "The schedule still runs while the app is in the menu bar.")
            }
            Section {
                Toggle("Skip duplicates in shared destinations", isOn: Binding(
                    get: { model.config.dedupeDestinations }, set: { _ in model.toggleDedupe() }))
            } footer: {
                Text("When two mirrors would write the same block into one calendar, only the first does.")
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
