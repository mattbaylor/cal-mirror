import SwiftUI
import UserNotifications

@main
struct CalMirrorMacApp: App {
    @StateObject private var model = Store()
    @StateObject private var notifications = RequestNotificationDelegate()
    @Environment(\.openWindow) private var openWindow

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
