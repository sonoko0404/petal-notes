import Foundation
import PetalCore

public enum AuthorizationState: Sendable, Equatable { case notDetermined, denied, authorized }
public enum ReminderSchedulingError: Error, Sendable { case identifierCollision }
public enum ReconcileResult: Sendable, Equatable { case scheduled, permissionRequired, permissionDenied, schedulingFailed }

public struct ReminderRequest: Sendable, Equatable, Codable {
    public let id: String
    public let cardID: CardID
    public let lineID: LineID
    public let body: String
    public let fireDate: Date
    public let sound: Bool
    public let category: String
    public var dailyComponents: DateComponents?
    public init(id: String, cardID: CardID, lineID: LineID, body: String, fireDate: Date,
                sound: Bool, category: String = "petal.todo") {
        self.id = id; self.cardID = cardID; self.lineID = lineID; self.body = body
        self.fireDate = fireDate; self.sound = sound; self.category = category
        self.dailyComponents = nil
    }
    public var isPetalOwned: Bool {
        category == "petal.todo" && (id == Self.baseID(lineID) || id == Self.baseID(lineID) + ".snooze")
    }
    public static func baseID(_ id: LineID) -> String { "line.\(id.rawValue.uuidString)" }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.cardID == rhs.cardID && lhs.lineID == rhs.lineID && lhs.body == rhs.body
        && lhs.sound == rhs.sound && lhs.category == rhs.category && lhs.dailyComponents == rhs.dailyComponents
        && (lhs.dailyComponents != nil || lhs.fireDate == rhs.fireDate)
    }
}

public protocol NotificationCenterAdapter: Sendable {
    func authorization() async -> AuthorizationState
    func requestAuthorization() async throws -> AuthorizationState
    func pending() async throws -> [ReminderRequest]
    func deliveredRequests() async throws -> [ReminderRequest]
    func add(_ request: ReminderRequest) async throws
    func remove(_ ids: [String]) async
    func removeDelivered(_ ids: [String]) async
    func registerActions() async
}

public protocol ReminderScheduling: Sendable {
    func authorizeForExplicitSave() async throws -> AuthorizationState
    func reconcile(lines: [CardLine], now: Date, calendar: Calendar) async throws -> ReconcileResult
    func cancel(lineID: LineID) async
    func complete(lineID: LineID) async throws
    func cancelAll() async throws
}
