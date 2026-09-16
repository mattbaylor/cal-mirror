import SwiftUI
import UserNotifications

@main
struct CalMirrorMacApp: App {
    @StateObject private var model = Store()
    @StateObject private var notifications = RequestNotificationDelegate()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .onAppear {
                    notifications.store = model
                    UNUserNotificationCenter.current().delegate = notifications
                }
        } label: {
            // The conflict window is declared below and something has to open
            // it. This hangs off the LABEL, not the menu: a MenuBarExtra's menu
            // only exists while it is open, so a conflict raised by a
            // notification action would find nothing listening. The label is
            // always in the hierarchy.
            Image(nsImage: menuBarImage(model.menuBarState))
                #if DEBUG
                // The synthetic Mac opens straight onto the window it is
                // photographing, as the key window.
                .task {
                    guard model.fixture else { return }
                    // After launch has finished: a window opened during it
                    // is laid out before its toolbar exists, and comes up
                    // with both panes scrolled under the title bar.
                    try? await Task.sleep(for: .seconds(1))
                    NSApp.setActivationPolicy(.regular)
                    if ProcessInfo.processInfo.arguments.contains("-CalMirrorFixtureSettings") {
                        openSettings()
                    } else {
                        openWindow(id: "manage")
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    // The name field would otherwise be first responder,
                    // with its text selected, in every frame.
                    try? await Task.sleep(for: .seconds(1))
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    if let size = MacFixture.size {
                        NSApp.keyWindow?.setContentSize(NSSize(width: size.width, height: size.height))
                    }
                }
                #endif
                .onChange(of: model.conflict) { _, conflict in
                    guard conflict != nil else { return }
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "conflict")
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .menuBarExtraStyle(.menu)

        Window("Manage Mirrors", id: "manage") {
            ManageView(model: model)
        }
        .defaultSize(width: 980, height: 640)

        // ⌘, — and the standard Settings… item in the app menu.
        Settings {
            SettingsView(model: model)
        }

        // The conflict sheet needs a window of its own on the Mac: a menu-bar
        // app has none to attach to, and the answer matters too much to be a
        // menu item that disappears when the mouse moves.
        Window("Request conflict", id: "conflict") {
            if let conflict = model.conflict {
                RequestConflictSheet(
                    conflict: conflict,
                    onDecline: { Task { await model.decline(conflict.request) } },
                    onAcceptAnyway: { Task { await model.acceptAnyway(conflict.request) } },
                    onLater: { model.conflict = nil })
                    .frame(minWidth: 460, minHeight: 520)
            }
        }
    }
}
