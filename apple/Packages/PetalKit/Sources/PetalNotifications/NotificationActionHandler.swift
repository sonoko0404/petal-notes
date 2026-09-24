import Foundation
import PetalCore
import UserNotifications

public enum NotificationAction: String, Sendable { case complete; case snoozeFiveMinutes = "snooze-5m"; case openCard = "open-card" }
public protocol NotificationActionHandling: Sendable {
    func handle(_ action: NotificationAction, lineID: LineID, cardID: CardID) async throws
}
public enum ReminderReconcileReason: Sendable, CaseIterable {
    case launch, foreground, localMutation, inboundSync, dateChange, timeZoneChange
}

/// Immutable Sendable dependencies; no framework response escapes its callback.
public final class NotificationResponseDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let handler: any NotificationActionHandling
    private let onFailure: @Sendable () async -> Void
    public init(handler: any NotificationActionHandling, onFailure: @escaping @Sendable () async -> Void) {
        self.handler = handler; self.onFailure = onFailure
    }
    public static func action(identifier: String) -> NotificationAction? {
        identifier == UNNotificationDefaultActionIdentifier ? .openCard : NotificationAction(rawValue: identifier)
    }
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await receive(request: response.notification.request, actionIdentifier: response.actionIdentifier)
    }
    public func receive(request nativeRequest: UNNotificationRequest, actionIdentifier: String) async {
        guard let action = Self.action(identifier: actionIdentifier),
              let request = SystemNotificationCenter.decode(nativeRequest) else { return }
        do { try await handler.handle(action, lineID: request.lineID, cardID: request.cardID) }
        catch { await onFailure() }
    }
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let request = SystemNotificationCenter.decode(notification.request) else { return [] }
        return request.sound ? [.banner, .sound] : [.banner]
    }
}
