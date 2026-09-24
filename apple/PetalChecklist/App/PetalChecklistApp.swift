import SwiftUI

@main
struct PetalChecklistApp: App {
    @State private var capture = QuickCaptureAppController()

    var body: some Scene {
        Window("Petal Checklist", id: "main") { RootView(capture: capture) }
            .defaultSize(width: 960, height: 640)
    }
}
