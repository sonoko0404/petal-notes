import Foundation
import PetalPersistence

public enum CloudTransportError: Error, Sendable, Equatable {
    case networkUnavailable, authenticationRequired, quotaExceeded, accountUnavailable, invalidRecord, conflict, unavailable
    case retryAfter(TimeInterval)
}

/// Safe diagnostic and server scheduling constraint are independent. No native
/// error, record, account identifier, or user content crosses this boundary.
/// The maximum duration is applied at operation completion (conservatively later
/// than receipt), then persisted as an absolute repository retryAt deadline.
public struct CloudTransportFailure: Error, Sendable, Equatable {
    public let reason: CloudTransportError
    public let maxRetryAfter: TimeInterval
    public init(reason: CloudTransportError, maxRetryAfter: TimeInterval) {
        self.reason = reason
        self.maxRetryAfter = maxRetryAfter.isFinite ? max(0, maxRetryAfter) : 0
    }
}

/// One order-independent reducer for native events, operation throws, and
/// nested partial errors. Diagnostic precedence never participates in timing.
struct CloudFailureSummary: Sendable {
    private(set) var reason: CloudTransportError?
    private(set) var maxRetryAfter: TimeInterval?
    mutating func include(_ reason: CloudTransportError?, retryAfter: TimeInterval? = nil) {
        if let retryAfter, retryAfter.isFinite { maxRetryAfter = max(maxRetryAfter ?? 0, retryAfter) }
        if case .retryAfter(let delay) = reason, delay.isFinite { maxRetryAfter = max(maxRetryAfter ?? 0, delay) }
        self.reason = [self.reason, reason].compactMap { $0 }.max { Self.priority($0) < Self.priority($1) }
    }
    var error: (any Error)? {
        guard let reason else { return nil }
        if let maxRetryAfter, case .retryAfter = reason { return CloudTransportError.retryAfter(maxRetryAfter) }
        if let maxRetryAfter { return CloudTransportFailure(reason: reason, maxRetryAfter: maxRetryAfter) }
        return reason
    }
    private static func priority(_ error: CloudTransportError) -> (Int, TimeInterval) {
        switch error {
        case .authenticationRequired: (9, 0)
        case .accountUnavailable: (8, 0)
        case .quotaExceeded: (7, 0)
        case .networkUnavailable: (6, 0)
        case .invalidRecord: (5, 0)
        case .unavailable: (4, 0)
        case .conflict: (3, 0)
        case .retryAfter(let delay): (2, delay.isFinite ? delay : 0)
        }
    }
}

public struct OutboundCloudChange: Sendable {
    public let record: ReplicatedRecord
    public let journal: [OutboxChange]
    public var id: UUID { journal.last!.id }
}

public protocol CloudTransport: Sendable {
    func fetchChanges(after token: Data?) async throws -> CloudFetchResult
    func send(_ changes: [OutboundCloudChange]) async throws -> CloudSendResult
    func cancel() async
}
public extension CloudTransport { func cancel() async {} }

public struct CloudFetchResult: Sendable {
    public let records: [ReplicatedRecord]
    public let token: Data?
    public init(records: [ReplicatedRecord], token: Data?) { self.records = records; self.token = token }
}

public struct CloudSendResult: Sendable {
    public let acceptedIDs: Set<UUID>
    public let token: Data?
    public let requiresRefetch: Bool
    public let maxRetryAfter: TimeInterval?
    public init(acceptedIDs: Set<UUID>, token: Data? = nil, requiresRefetch: Bool = false, maxRetryAfter: TimeInterval? = nil) {
        self.acceptedIDs = acceptedIDs; self.token = token; self.requiresRefetch = requiresRefetch
        self.maxRetryAfter = maxRetryAfter
    }
}
