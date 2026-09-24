import SwiftUI
import PetalNotifications

extension Notification.Name {
    static let petalCloudPushReceived = Notification.Name("petal.cloud.pushReceived")
}

@main
struct PetalChecklistApp: App {
    @NSApplicationDelegateAdaptor(PetalAppDelegate.self) private var appDelegate
    @State private var capture = QuickCaptureAppController()

    var body: some Scene {
        Window("Petal Checklist", id: "main") { RootView(capture: capture, notificationBroker: appDelegate.notificationBroker) }
            .defaultSize(width: 960, height: 640)
    }
}

@MainActor
final class PetalAppDelegate: NSObject, NSApplicationDelegate {
    let notificationBroker = NotificationResponseBroker()
    private var notificationDelegate: NotificationResponseDelegate?
    override init() {
        super.init()
        let broker = notificationBroker
        let delegate = NotificationResponseDelegate(handler: broker, onFailure: { await broker.recordFailure() })
        notificationDelegate = delegate
        // Synchronous installation during app-delegate construction precedes
        // launch completion and all asynchronous repository/view setup.
        SystemNotificationCenter.installLaunchDelegate(delegate)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppEnvironment.isTestRun else { return }
        NSApplication.shared.registerForRemoteNotifications()
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        NotificationCenter.default.post(name: .petalCloudPushReceived, object: nil)
    }
}
