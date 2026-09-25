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
        Window("ui.petal_checklist.d92314", id: "main") {
            RootView(capture: capture, notificationBroker: appDelegate.notificationBroker,
                     terminationCoordinator: appDelegate.terminationCoordinator)
        }
            .defaultSize(width: 960, height: 640)
    }
}

@MainActor
final class ApplicationTerminationCoordinator {
    var prepare: (@MainActor () async -> Bool)?
    private var requestTask: Task<Void, Never>?

    func request(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard let prepare else { return .terminateNow }
        guard requestTask == nil else { return .terminateLater }
        requestTask = Task { @MainActor [weak self] in
            let allowed = await prepare()
            reply(allowed)
            self?.requestTask = nil
        }
        return .terminateLater
    }
}

@MainActor
final class PetalAppDelegate: NSObject, NSApplicationDelegate {
    let notificationBroker = NotificationResponseBroker()
    let terminationCoordinator = ApplicationTerminationCoordinator()
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationCoordinator.request { sender.reply(toApplicationShouldTerminate: $0) }
    }
}
