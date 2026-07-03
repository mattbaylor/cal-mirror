import SwiftUI

@main
struct CalMirrorMacApp: App {
    @StateObject private var model = MacModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.overallIcon)
        }
        .menuBarExtraStyle(.menu)

        Window("Manage Mirrors", id: "manage") {
            ManageView(model: model)
        }
    }
}
