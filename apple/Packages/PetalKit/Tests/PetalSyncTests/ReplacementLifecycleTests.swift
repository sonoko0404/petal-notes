import CloudKit
import Foundation
import Testing
import PetalCore
import PetalPersistence
@testable import PetalSync

private let lifecycleNow = Date(timeIntervalSince1970: 1_800_000_000)

private func lifecycleOrders(_ values: [Int]) -> [[Int]] {
    if values.isEmpty { return [[]] }
    return values.flatMap { value in lifecycleOrders(values.filter { $0 != value }).map { [value] + $0 } }
}

private actor LifecycleServer: CloudTransport {
    private var records: [String: CKRecord] = [:]
    private(set) var history: [ReplicatedRecord] = []
    private var rejectClear: Bool
    init(rejectClear: Bool = false) { self.rejectClear = rejectClear }
    func allowClear() { rejectClear = false }
    func fetchChanges(after token: Data?) async throws -> CloudFetchResult {
        CloudFetchResult(records: try records.values.map(CloudRecordMapper.decode), token: nil)
    }
    func send(_ changes: [OutboundCloudChange]) async throws -> CloudSendResult {
        for change in changes {
            if rejectClear, case .userState(let state) = change.record.payload, state.replacementMode == false {
                throw CloudTransportError.unavailable
            }
            let record = try CloudRecordMapper.encode(change.record)
            records[record.recordID.recordName] = record
            history.append(try CloudRecordMapper.decode(record))
        }
        return CloudSendResult(acceptedIDs: Set(changes.map(\.id)))
    }
}

@Test func replacementClearFailureRetainsOneDurableIntentAcrossDiskRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    }
    let repository = try open()
    let card = try await repository.createCard(title: "Persisted", now: lifecycleNow)
    try await repository.replaceUserData(repository.transferSnapshot(), now: lifecycleNow)
    let server = LifecycleServer(rejectClear: true)
    await CloudSyncCoordinator(repository: repository, transport: server, now: { lifecycleNow }).sync(reason: .userRequested)
    let pending = try await repository.pendingOutbox()
    #expect(pending.count == 1)
    #expect(pending.first?.entity == .userState)
    let state = try JSONDecoder().decode(UserStateChange.self, from: #require(pending.first?.payload))
    #expect(state.revision == 2 && state.replacementMode == false)
    #expect(try await repository.card(id: card.id)?.title == "Persisted")
    let reopened = try open()
    await server.allowClear()
    await CloudSyncCoordinator(repository: reopened, transport: server, now: { lifecycleNow.addingTimeInterval(10) }).sync(reason: .launch)
    #expect(try await reopened.pendingOutboxCount() == 0)
    let states = await server.history.compactMap { record -> UserStateChange? in if case .userState(let state) = record.payload { return state }; return nil }
    #expect(states.map(\.revision) == [1, 2])
}

@Test func orderedCurrentInboxSurvivesOlderMarkersAndUsesDeterministicDeviceTie() async throws {
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let initial = try await sender.createCard(title: "Initial", now: lifecycleNow)
    let b = try await sender.createCard(title: "B", now: lifecycleNow)
    let c = try await sender.createCard(title: "C", now: lifecycleNow)
    try await sender.replaceUserData(sender.transferSnapshot(), now: lifecycleNow)
    let records = try await CloudRecordMapper.outbound(sender.syncSnapshot()).map(\.record)
    let generation = try await sender.syncSnapshot().generation
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }))
    }
    try await open().applyInbound(records, token: nil, now: lifecycleNow)
    func update(_ inbox: CardID, revision: Int64, device: String, date: Date) -> ReplicatedRecord {
        ReplicatedRecord(payload: .userState(UserStateChange(resetGeneration: generation.id, inboxCardID: inbox,
            replacementMode: false, revision: revision, modifiedAt: date, deviceID: device)), generation: generation)
    }
    try await open().applyInbound([update(b.id, revision: 2, device: "A", date: lifecycleNow)], token: nil, now: lifecycleNow)
    try await open().applyInbound([update(c.id, revision: 2, device: "Z", date: lifecycleNow)], token: nil, now: lifecycleNow)
    try await open().applyInbound([update(initial.id, revision: 1, device: "Z", date: lifecycleNow.addingTimeInterval(100))] + records,
        token: nil, now: lifecycleNow)
    let result = try open()
    #expect(try await result.cards(scope: .active).filter(\.isInbox).map(\.id) == [c.id])
    #expect(try await result.syncSnapshot().replacementDeliveryStatus == .complete)
}

@Test func replacementPublishesClearOnlyAfterAllRestoredContentIsAcknowledged() async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    _ = try await repository.createCard(title: "Restored", now: lifecycleNow)
    try await repository.replaceUserData(repository.transferSnapshot(), now: lifecycleNow)
    let server = LifecycleServer()
    await CloudSyncCoordinator(repository: repository, transport: server, now: { lifecycleNow }).sync(reason: .userRequested)
    let history = await server.history
    let states = history.compactMap { record -> UserStateChange? in if case .userState(let state) = record.payload { return state }; return nil }
    #expect(states.map(\.replacementMode) == [true, false])
    #expect(states.map(\.revision) == [1, 2])
    #expect(history.count == 3)
    if history.count == 3 { #expect({ if case .card = history[1].payload { true } else { false } }()) }
    #expect(try await repository.pendingOutboxCount() == 0)
}

@Test(arguments: ["archive", "trash", "purge"], [false, true])
func lateReplacementDeviceConvergesAfterOriginalInboxLifecycle(action: String, uploadedFirst: Bool) async throws {
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let original = try await sender.createCard(title: "Original Inbox", now: lifecycleNow)
    try await sender.replaceUserData(sender.transferSnapshot(), now: lifecycleNow)
    let server = LifecycleServer()
    if uploadedFirst { await CloudSyncCoordinator(repository: sender, transport: server, now: { lifecycleNow }).sync(reason: .userRequested) }
    try await sender.moveCardEnsuringInbox(original.id, to: action == "archive" ? .archived : .trashed,
        replacementInbox: nil, now: lifecycleNow.addingTimeInterval(10))
    let later = lifecycleNow.addingTimeInterval(2_592_011)
    if action == "purge" { try await sender.purgeExpiredTrash(now: later) }
    let expectedInbox = try #require(await sender.cards(scope: .active).first(where: \.isInbox))
    await CloudSyncCoordinator(repository: sender, transport: server, now: { action == "purge" ? later : lifecycleNow.addingTimeInterval(11) }).sync(reason: .userRequested)
    let late = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let latest = try await server.fetchChanges(after: nil)
    try await late.applyInbound(latest.records, token: latest.token, now: later)
    #expect(try await late.cards(scope: .active).filter(\.isInbox).map(\.id) == [expectedInbox.id])
    #expect(try await late.cards(scope: .all).count == (action == "purge" ? 1 : 2))
    #expect(try await late.card(id: original.id)?.status == (action == "purge" ? nil : action == "archive" ? .archived : .trashed))
}

@Test(arguments: [false, true]) func completedReceiverUsesDisposablePlaceholderDuringLaterInboxGap(edited: Bool) async throws {
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let original = try await sender.createCard(title: "Original", now: lifecycleNow)
    try await sender.replaceUserData(sender.transferSnapshot(), now: lifecycleNow)
    let server = LifecycleServer()
    await CloudSyncCoordinator(repository: sender, transport: server, now: { lifecycleNow }).sync(reason: .userRequested)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open(fault: RepositoryFaultInjector = .none) throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }), faultInjector: fault)
    }
    let receiver = try open()
    try await receiver.applyInbound(server.fetchChanges(after: nil).records, token: nil, now: lifecycleNow)
    try await sender.moveCardEnsuringInbox(original.id, to: .archived, replacementInbox: nil, now: lifecycleNow.addingTimeInterval(10))
    await CloudSyncCoordinator(repository: sender, transport: server, now: { lifecycleNow.addingTimeInterval(11) }).sync(reason: .userRequested)
    let current = try await server.fetchChanges(after: nil).records
    let archivePage = current.filter { CloudRecordMapper.identity($0).id == original.id.rawValue }
    try await receiver.applyInbound(archivePage, token: nil, now: lifecycleNow.addingTimeInterval(12))
    #expect(try await receiver.cards(scope: .active).filter(\.isInbox).count == 1)
    #expect(try await receiver.pendingOutboxCount() == 0)
    let provisional = try #require(await receiver.cards(scope: .active).first)
    if edited {
        _ = try await receiver.updateCardTitle(provisional.id, title: "Keep gap edit", now: lifecycleNow.addingTimeInterval(12))
        try await receiver.acknowledgeSync(receiver.pendingOutbox())
    }
    let reopened = try open()
    try await reopened.applyInbound(current, token: nil, now: lifecycleNow.addingTimeInterval(13))
    #expect(try await reopened.cards(scope: .all).count == (edited ? 3 : 2))
    if edited {
        #expect(try await reopened.card(id: provisional.id)?.title == "Keep gap edit")
        #expect(try await reopened.card(id: provisional.id)?.isInbox == false)
        #expect(try await reopened.pendingOutboxCount() > 0)
    } else { #expect(try await reopened.pendingOutboxCount() == 0) }
}

@Test(arguments: ["archive", "trash", "purge"], lifecycleOrders([0, 1, 2, 3]))
func replacementLifecyclePagesConvergeAcrossEveryOrderAndRestart(action: String, order: [Int]) async throws {
    let sender = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    let original = try await sender.createCard(title: "Initial", now: lifecycleNow)
    try await sender.replaceUserData(sender.transferSnapshot(), now: lifecycleNow)
    let server = LifecycleServer()
    await CloudSyncCoordinator(repository: sender, transport: server, now: { lifecycleNow }).sync(reason: .userRequested)
    let initialHistory = await server.history
    let initialMarker = try #require(initialHistory.first)
    let initialClear = try #require(initialHistory.last)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func open(fault: RepositoryFaultInjector = .none) throws -> SwiftDataPetalRepository {
        SwiftDataPetalRepository(container: try ModelContainerFactory.makeShared(appGroupID: "test", containerURL: { _ in root }), faultInjector: fault)
    }
    let receiver = try open()
    try await receiver.applyInbound([initialMarker], token: Data([1]), now: lifecycleNow)
    let placeholder = try #require(await receiver.cards(scope: .active).first)
    _ = try await receiver.updateCardTitle(placeholder.id, title: "Local uploaded edit", now: lifecycleNow.addingTimeInterval(1))
    let upload = try await CloudRecordMapper.outbound(receiver.syncSnapshot())
    let echoes = upload.map(\.record)
    _ = try await server.send(upload)
    try await receiver.acknowledgeSync(upload.flatMap(\.journal))
    _ = try await receiver.updateCardTitle(placeholder.id, title: "Second local edit", now: lifecycleNow.addingTimeInterval(20))
    let line = try await receiver.addLine(NewLineDraft(cardID: placeholder.id, kind: .todo, text: "Unsent capture"), now: lifecycleNow.addingTimeInterval(20))
    try await sender.moveCardEnsuringInbox(original.id, to: action == "archive" ? .archived : .trashed,
        replacementInbox: nil, now: lifecycleNow.addingTimeInterval(10))
    let later = lifecycleNow.addingTimeInterval(2_592_011)
    if action == "purge" { try await sender.purgeExpiredTrash(now: later) }
    let currentInbox = try #require(await sender.cards(scope: .active).first(where: \.isInbox))
    await CloudSyncCoordinator(repository: sender, transport: server,
        now: { action == "purge" ? later : lifecycleNow.addingTimeInterval(11) }).sync(reason: .userRequested)
    let current = try await server.fetchChanges(after: nil).records
    let finalState = current.filter { if case .userState = $0.payload { true } else { false } }
    let originalLifecycle = current.filter { CloudRecordMapper.identity($0).id == original.id.rawValue }
    let currentInboxPage = current.filter { CloudRecordMapper.identity($0).id == currentInbox.id.rawValue }
    let pages = [originalLifecycle, currentInboxPage, [initialClear], finalState]
    for step in order {
        let reopened = try open()
        if step == 3 {
            let before = try await reopened.transferSnapshot()
            let journal = try await reopened.pendingOutbox()
            let expectedID = try await reopened.syncSnapshot().replacementExpectedInboxID
            let failing = try open(fault: .failOnceBeforeSave)
            await #expect(throws: RepositoryError.injectedFailure) {
                try await failing.applyInbound(pages[step], token: Data([99]), now: lifecycleNow.addingTimeInterval(30))
            }
            #expect(try await reopened.transferSnapshot() == before)
            #expect(try await reopened.pendingOutbox() == journal)
            #expect(try await reopened.syncSnapshot().replacementExpectedInboxID == expectedID)
        }
        try await reopened.applyInbound(pages[step], token: Data([UInt8(step + 2)]), now: lifecycleNow.addingTimeInterval(30))
        // Server echoes and the oldest marker can appear after every checkpoint.
        try await reopened.applyInbound(echoes + [initialMarker, initialMarker], token: nil, now: lifecycleNow.addingTimeInterval(30))
        #expect(try await reopened.cards(scope: .active).filter(\.isInbox).count == 1)
    }
    let final = try open()
    try await final.applyInbound(current + echoes + [initialMarker], token: nil, now: later.addingTimeInterval(1))
    #expect(try await final.cards(scope: .active).filter(\.isInbox).map(\.id) == [currentInbox.id])
    #expect(try await final.card(id: placeholder.id)?.title == "Second local edit")
    #expect(try await final.card(id: placeholder.id)?.isInbox == false)
    #expect(try await final.lines(cardID: placeholder.id).contains { $0.id == line.id })
    #expect(try await final.pendingOutbox().contains { $0.entityID == line.id.rawValue })
    #expect(try await final.syncSnapshot().replacementDeliveryStatus == .complete)
}
