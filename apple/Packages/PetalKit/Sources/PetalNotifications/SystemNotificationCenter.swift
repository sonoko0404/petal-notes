import Foundation
import UserNotifications
import PetalCore

/// The framework object stays inside this actor; only domain values cross it.
public actor SystemNotificationCenter: NotificationCenterAdapter {
    private let center = UNUserNotificationCenter.current()
    public init() {}
    @MainActor public static func installLaunchDelegate(_ delegate: NotificationResponseDelegate) {
        UNUserNotificationCenter.current().delegate = delegate
    }
    public func authorization() async -> AuthorizationState {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
    public func requestAuthorization() async throws -> AuthorizationState {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }
    public func registerActions() async {
        var categories = await center.notificationCategories()
        categories = categories.filter { $0.identifier != "petal.todo" }
        categories.insert(UNNotificationCategory(identifier: "petal.todo", actions: Self.actions(), intentIdentifiers: []))
        center.setNotificationCategories(categories)
    }
    public func pending() async throws -> [ReminderRequest] {
        await center.pendingNotificationRequests().compactMap(Self.decode)
    }
    public func add(_ request: ReminderRequest) async throws {
        if let existing = await center.pendingNotificationRequests().first(where: { $0.identifier == request.id }),
           Self.decode(existing)?.isPetalOwned != true { throw ReminderSchedulingError.identifierCollision }
        try await center.add(Self.makeRequest(request))
    }
    public func remove(_ ids: [String]) async {
        // Check category as well as the exact identifier before touching pending requests.
        let owned = await center.pendingNotificationRequests().filter {
            ids.contains($0.identifier) && Self.decode($0)?.isPetalOwned == true
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: owned)
        await removeDelivered(ids)
    }
    public func removeDelivered(_ ids: [String]) async {
        let delivered = await center.deliveredNotifications().filter {
            ids.contains($0.request.identifier) && Self.decode($0.request)?.isPetalOwned == true
        }.map { $0.request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }
    public nonisolated static func actions() -> [UNNotificationAction] {
        [UNNotificationAction(identifier: "complete", title: String(localized: "Complete", bundle: .module)),
         UNNotificationAction(identifier: "snooze-5m", title: String(localized: "Snooze 5 Minutes", bundle: .module)),
         UNNotificationAction(identifier: "open-card", title: String(localized: "Open Card", bundle: .module), options: [.foreground])]
    }
    public nonisolated static func makeRequest(_ request: ReminderRequest) throws -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.body = request.body
        content.categoryIdentifier = request.category
        content.sound = request.sound ? .default : nil
        content.userInfo = ["petal.request": try JSONEncoder().encode(request)]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: request.fireDate)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: request.id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: request.dailyComponents ?? components,
                repeats: request.dailyComponents != nil))
    }
    public nonisolated static func decode(_ request: UNNotificationRequest) -> ReminderRequest? {
        guard request.content.categoryIdentifier == "petal.todo",
              let data = request.content.userInfo["petal.request"] as? Data,
              let value = try? JSONDecoder().decode(ReminderRequest.self, from: data),
              value.id == request.identifier, value.isPetalOwned else { return nil }
        return value
    }
}
