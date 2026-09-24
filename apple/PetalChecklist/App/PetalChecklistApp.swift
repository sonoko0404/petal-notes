import SwiftUI

@main
struct PetalChecklistApp: App {
    var body: some Scene {
        Window("Petal Checklist", id: "main") { RootView() }
            .defaultSize(width: 960, height: 640)
    }
}
