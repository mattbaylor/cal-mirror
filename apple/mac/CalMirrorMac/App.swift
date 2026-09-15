import SwiftUI
import UserNotifications

@main
struct CalMirrorMacApp: App {
    @StateObject private var model = Store()
    @StateObject private var notifications = RequestNotificationDelegate()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .onAppear {
                    notifications.store = model
                    UNUserNotificationCenter.current().delegate = notifications
                }
        } label: {
            Image(nsImage: menuBarImage(model.menuBarState))
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
