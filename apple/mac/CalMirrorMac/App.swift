import SwiftUI

@main
struct CalMirrorMacApp: App {
    @StateObject private var model = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: menuBarImage(model.menuBarState))
        }
        .menuBarExtraStyle(.menu)

        Window("Manage Mirrors", id: "manage") {
            ManageView(model: model)
        }
    }
}
