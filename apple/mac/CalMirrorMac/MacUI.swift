import SwiftUI
import CalMirrorKit

// MARK: - Menu bar dropdown

struct MenuContent: View {
    @ObservedObject var model: MacModel
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
    @ObservedObject var model: MacModel

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
    @ObservedObject var model: MacModel
    @Binding var m: Mirror
    @State private var conflict: String?

    private func calId(_ title: String, _ account: String?) -> String {
        if let a = account, let c = model.calendars.first(where: { $0.title == title && $0.account == a }) { return c.identifier }
        return model.calendars.first(where: { $0.title == title })?.identifier ?? ""
    }
    private func picker(_ isSource: Bool) -> Binding<String> {
        Binding(
            get: { isSource ? calId(m.source.title, m.source.account) : calId(m.dest.title, m.dest.account) },
            set: { id in
                guard let c = model.calendars.first(where: { $0.identifier == id }) else { return }
                let newSource = isSource ? CalRef(title: c.title, account: c.account) : m.source
                let newDest   = isSource ? m.dest : CalRef(title: c.title, account: c.account)
                if let clash = model.reverseConflict(source: newSource, dest: newDest, excluding: m.id) {
                    conflict = "Can’t reverse “\(clash.name)” — the copy would loop back."; return
                }
                conflict = nil
                if isSource { m.source = newSource } else { m.dest = newDest }
                model.save()
            })
    }

    var body: some View {
        TextField("Name", text: $m.name).onSubmit { model.save() }
        Picker("Source", selection: picker(true)) {
            Text("— choose —").tag("")
            ForEach(model.calendars) { c in Text(c.label).tag(c.identifier) }
        }
        Picker("Destination", selection: picker(false)) {
            Text("— choose —").tag("")
            ForEach(model.calendars.filter { $0.writable }) { c in Text(c.label).tag(c.identifier) }
        }
        if let conflict {
            Label(conflict, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        }
        Toggle("Heartbeat banner", isOn: $m.showHeartbeat).onChange(of: m.showHeartbeat) { _, _ in model.save() }
        Stepper("History window: \(Int(m.windowPastDays)) days", value: $m.windowPastDays, in: 1...3650, step: 5)
            .onChange(of: m.windowPastDays) { _, _ in model.save() }
        Stepper("Future window: \(Int(m.windowFutureDays)) days", value: $m.windowFutureDays, in: 1...3650, step: 30)
            .onChange(of: m.windowFutureDays) { _, _ in model.save() }
        Button(role: .destructive) { model.delete(m.id) } label: { Label("Remove mirror", systemImage: "trash") }
    }
}
