import CloudKit
import Foundation
import PetalPersistence

public protocol SyncEngineDriving: Sendable {
    func fetch(checkpoint: Data?) async throws -> CloudFetchResult
    func send(_ records: [ReplicatedRecord]) async throws -> EngineSendResult
    func cancel() async
}
public struct EngineSendResult: Sendable {
    public let savedRecordIDs: Set<UUID>
    public let checkpoint: Data?
    public let requiresRefetch: Bool
    public let maxRetryAfter: TimeInterval?
    public init(savedRecordIDs: Set<UUID>, checkpoint: Data?, requiresRefetch: Bool = false, maxRetryAfter: TimeInterval? = nil) {
        self.savedRecordIDs = savedRecordIDs; self.checkpoint = checkpoint; self.requiresRefetch = requiresRefetch
        self.maxRetryAfter = maxRetryAfter
    }
}

public struct CKSyncTransport: CloudTransport {
    private let engine: any SyncEngineDriving
    public init(engine: any SyncEngineDriving) { self.engine = engine }
    public func fetchChanges(after token: Data?) async throws -> CloudFetchResult {
        do { return try await engine.fetch(checkpoint: token) }
        catch { throw Self.safeFailure(error) }
    }
    public func send(_ changes: [OutboundCloudChange]) async throws -> CloudSendResult {
        do {
            let result = try await engine.send(changes.map(\.record))
            return CloudSendResult(acceptedIDs: Set(changes.filter {
                result.savedRecordIDs.contains(CloudRecordMapper.identity($0.record).id)
            }.map(\.id)), token: result.checkpoint, requiresRefetch: result.requiresRefetch, maxRetryAfter: result.maxRetryAfter)
        } catch { throw Self.safeFailure(error) }
    }
    public func cancel() async { await engine.cancel() }
    static func safeFailure(_ error: any Error) -> any Error {
        summary(error).error ?? CloudTransportError.unavailable
    }
    static func summary(_ error: any Error) -> CloudFailureSummary {
        var result = CloudFailureSummary()
        if let safe = error as? CloudTransportFailure { result.include(safe.reason, retryAfter: safe.maxRetryAfter); return result }
        if let safe = error as? CloudTransportError { result.include(safe); return result }
        guard let cloud = error as? CKError else { result.include(.unavailable); return result }
        let delay = cloud.retryAfterSeconds ?? (cloud.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        result.include(nil, retryAfter: delay)
        if cloud.code == .partialFailure,
           let children = cloud.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error], !children.isEmpty {
            for child in children.values {
                let nested = summary(child)
                result.include(nested.reason, retryAfter: nested.maxRetryAfter)
            }
            return result
        }
        let reason: CloudTransportError
        switch cloud.code {
        case .networkFailure, .networkUnavailable: reason = .networkUnavailable
        case .notAuthenticated: reason = .authenticationRequired
        case .accountTemporarilyUnavailable: reason = .accountUnavailable
        case .quotaExceeded: reason = .quotaExceeded
        case .serverRecordChanged: reason = .conflict
        default: reason = result.maxRetryAfter.map { .retryAfter($0) } ?? .unavailable
        }
        result.include(reason)
        return result
    }
    public static func failure(_ error: any Error) -> CloudTransportError {
        summary(error).reason ?? .unavailable
    }
}
