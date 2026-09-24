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
    public init(savedRecordIDs: Set<UUID>, checkpoint: Data?, requiresRefetch: Bool = false) {
        self.savedRecordIDs = savedRecordIDs; self.checkpoint = checkpoint; self.requiresRefetch = requiresRefetch
    }
}

public struct CKSyncTransport: CloudTransport {
    private let engine: any SyncEngineDriving
    public init(engine: any SyncEngineDriving) { self.engine = engine }
    public func fetchChanges(after token: Data?) async throws -> CloudFetchResult {
        do { return try await engine.fetch(checkpoint: token) }
        catch { throw Self.failure(error) }
    }
    public func send(_ changes: [OutboundCloudChange]) async throws -> CloudSendResult {
        do {
            let result = try await engine.send(changes.map(\.record))
            return CloudSendResult(acceptedIDs: Set(changes.filter {
                result.savedRecordIDs.contains(CloudRecordMapper.identity($0.record).id)
            }.map(\.id)), token: result.checkpoint, requiresRefetch: result.requiresRefetch)
        } catch { throw Self.failure(error) }
    }
    public func cancel() async { await engine.cancel() }
    public static func failure(_ error: any Error) -> CloudTransportError {
        if let safe = error as? CloudTransportError { return safe }
        guard let cloud = error as? CKError else { return .unavailable }
        if let delay = cloud.retryAfterSeconds ?? (cloud.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue,
           delay.isFinite { return .retryAfter(max(0, delay)) }
        switch cloud.code {
        case .networkFailure, .networkUnavailable: return .networkUnavailable
        case .notAuthenticated: return .authenticationRequired
        case .accountTemporarilyUnavailable: return .accountUnavailable
        case .quotaExceeded: return .quotaExceeded
        case .serverRecordChanged: return .conflict
        default: return .unavailable
        }
    }
}
