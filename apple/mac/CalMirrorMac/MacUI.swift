import SwiftUI
import CalMirrorKit

// MARK: - Menu bar dropdown

struct MenuContent: View {
    @ObservedObject var model: Store
    @Environment(\.openWindow) private var openWindow
    private let intervals: [(String, Int)] = [("5 min", 300), ("15 min", 900), ("30 min", 1800), ("1 hour", 3600)]

    var body: some View {
        Text("cal-mirror — \(model.headline)")
        if model.config.mirrors.isEmpty { Text("No mirrors yet").font(.caption) }
        ForEach(model.config.mirrors) { m in
            let s = model.statuses[m.id]
            Menu("\(symbol(model.iconFor(m.id)))  \(m.name)") {
                if let s, let e = s.error, !e.isEmpty { Text("⚠︎ \(e)") }
                else if let s { Text("\(s.total) events  (+\(s.created) ~\(s.updated) −\(s.deleted))") }
                Text("\(m.source.title)  →  \(m.dest.title)").font(.caption)
                Divider()
                Toggle("Enabled", isOn: Binding(get: { m.enabled }, set: { _ in model.toggleEnabled(m.id) }))
                Toggle("Heartbeat banner", isOn: Binding(get: { m.showHeartbeat }, set: { _ in model.toggleHeartbeat(m.id) }))
            }
        }
        Divider()
        Button(model.config.paused ? "Resume syncing" : "Sync now") {
            if model.config.paused { model.togglePause() } else { Task { await model.syncNow() } }
        }
        Button("Pause syncing") { model.togglePause() }.disabled(model.config.paused)
        Menu("Sync interval") {
            ForEach(intervals, id: \.1) { name, secs in
                Button(name + (model.config.intervalSeconds == secs ? "  ✓" : "")) { model.setInterval(secs) }
            }
        }
        Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Divider()
        Button("Manage mirrors…") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "manage")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Calendar") { NSWorkspace.shared.open(URL(string: "ical://")!) }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
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

struct ManageView: View {
    @ObservedObject var model: Store

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Mirror pairs").font(.headline)
                    Spacer()
                    Button { model.addMirror() } label: { Label("Add mirror", systemImage: "plus") }
                }
                if !model.access {
                    Text("Calendar access not granted yet — grant it so the pickers can list your calendars.")
                        .foregroundStyle(.orange)
                }
                if model.config.mirrors.isEmpty {
                    Text("No mirrors yet. Click “Add mirror”.").foregroundStyle(.secondary)
                }
            }
            ForEach($model.config.mirrors) { $m in
                Section(header: Text($m.wrappedValue.name.isEmpty ? "Mirror" : $m.wrappedValue.name)) {
                    MacMirrorRow(model: model, m: $m)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 640, minHeight: 480)
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

struct MacMirrorRow: View {
    @ObservedObject var model: Store
    @Binding var m: Mirror

    var body: some View {
        MirrorFields(
            mirror: $m,
            calendars: model.calendars,
            reverseConflict: { s, d in model.reverseConflict(source: s, dest: d, excluding: m.id) },
            onChange: { model.save() })
        Button(role: .destructive) { model.delete(m.id) } label: { Label("Remove mirror", systemImage: "trash") }
    }
}
