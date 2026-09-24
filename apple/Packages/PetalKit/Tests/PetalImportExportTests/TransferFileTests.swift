import Foundation
import Testing
import PetalCore
import PetalPersistence
import PetalImportExport

private final class TransferFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let lock = NSLock()
    private var count = 0
    init(_ url: URL) { presentedItemURL = url; super.init() }
    var coordinatedWrites: Int { lock.lock(); defer { lock.unlock() }; return count }
    func relinquishPresentedItem(toWriter writer: @Sendable @escaping ((@Sendable () -> Void)?) -> Void) {
        lock.lock(); count += 1; lock.unlock()
        writer(nil)
    }
}

@Test func jsonWriterCoordinatesOnlyTheSelectedFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let selected = root.appendingPathComponent("selected.json")
    try Data("old".utf8).write(to: selected)
    let presenter = TransferFilePresenter(selected)
    NSFileCoordinator.addFilePresenter(presenter)
    defer { NSFileCoordinator.removeFilePresenter(presenter) }
    try TransferFileWriter.write(Data("new".utf8), to: selected)
    #expect(presenter.coordinatedWrites > 0)
    #expect(try Data(contentsOf: selected) == Data("new".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["selected.json"])
}

@Test func importWritesUsableBackupBeforeCommitAndRetainsItOnSaveFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let backup = root.appendingPathComponent("Before.json")
    let store = try ModelContainerFactory.makeInMemory()
    let repository = SwiftDataPetalRepository(container: store)
    try await repository.bootstrap(now: transferNow)
    let failing = SwiftDataPetalRepository(container: store, faultInjector: .failBeforeSave)
    let service = DataTransferService(repository: failing)
    await #expect(throws: RepositoryError.injectedFailure) {
        try await service.importWindows(windowsFixture(), backupURL: backup, settings: TransferSettings(notificationSoundEnabled: true),
            timeZone: .gmt, fallbackTitle: "Imported reminder", now: transferNow)
    }
    let restored = try PetalBackupCodec.decode(Data(contentsOf: backup))
    #expect(restored.snapshot.cards.map(\.title) == ["Inbox"])
    #expect(restored.settings.notificationSoundEnabled)
    #expect(try await repository.cards(scope: .all).count == 1)
    let success = DataTransferService(repository: repository)
    #expect(try await success.importWindows(windowsFixture(), backupURL: backup, settings: TransferSettings(),
        timeZone: .gmt, fallbackTitle: "Imported reminder", now: transferNow) == 1)
    #expect(try PetalBackupCodec.decode(Data(contentsOf: backup)).snapshot.cards.map(\.title) == ["Inbox"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Before.json"])
}

@Test func atomicWriterReplacesOnlyDestinationAndCleansTemporaryFileOnFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("backup.json")
    try Data("old".utf8).write(to: file)
    try TransferFileWriter.write(Data("new".utf8), to: file)
    #expect(try String(contentsOf: file, encoding: .utf8) == "new")
    let directory = root.appendingPathComponent("directory")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try TransferFileWriter.write(Data(), to: directory) }
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["backup.json", "directory"])
}

@Test func serviceExportAndRestoreReplaceUserDataAndReturnSettings() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    try await repository.bootstrap(now: transferNow)
    let service = DataTransferService(repository: repository)
    try await service.exportBackup(to: file, settings: TransferSettings(notificationSoundEnabled: true))
    let bytes = try Data(contentsOf: file)
    #expect(try PetalBackupCodec.decode(bytes).snapshot.cards.map(\.title) == ["Inbox"])
    _ = try await repository.createCard(title: "After backup", now: transferNow)
    let settings = try await service.restore(bytes, now: transferNow)
    #expect(settings.notificationSoundEnabled)
    #expect(try await repository.cards(scope: .all).map(\.title) == ["Inbox"])
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try await service.exportMarkdown(to: folder, languageCode: "en")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
}

@Test func invalidTailFutureBackupAndDiskFailureLeaveLogicalStateUnchanged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let backup = root.appendingPathComponent("before.json")
    try Data("existing backup".utf8).write(to: backup)
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    try await repository.bootstrap(now: transferNow)
    let before = try await repository.transferSnapshot()
    let outbox = try await repository.pendingOutbox()
    let service = DataTransferService(repository: repository)
    var document = try #require(JSONSerialization.jsonObject(with: windowsFixture()) as? [String: Any])
    var notes = try #require(document["Notes"] as? [[String: Any]])
    var invalid = notes[0]
    invalid["Id"] = UUID().uuidString
    invalid["Todos"] = NSNull()
    notes.append(invalid); document["Notes"] = notes
    let broken = try JSONSerialization.data(withJSONObject: document)
    await #expect(throws: (any Error).self) {
        try await service.importWindows(broken, backupURL: backup, settings: TransferSettings(), timeZone: .gmt,
            fallbackTitle: "Imported reminder", now: transferNow)
    }
    #expect(try String(contentsOf: backup, encoding: .utf8) == "existing backup")
    await #expect(throws: TransferError.unsupportedVersion(99)) {
        try await service.restore(Data(#"{"schemaVersion":99}"#.utf8), now: transferNow)
    }
    await #expect(throws: (any Error).self) {
        try await service.importWindows(windowsFixture(), backupURL: root.appendingPathComponent("missing/backup.json"),
            settings: TransferSettings(), timeZone: .gmt, fallbackTitle: "Imported reminder", now: transferNow)
    }
    #expect(try await repository.transferSnapshot() == before)
    #expect(try await repository.pendingOutbox() == outbox)
}

@Test(arguments: ["Due", "DeletedAt"])
func invalidLegacyCalendarDateRejectsEntireFileBeforeBackup(_ field: String) async throws {
    let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
    try await repository.bootstrap(now: transferNow)
    let before = try await repository.transferSnapshot()
    let journal = try await repository.pendingOutbox()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("previous backup".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    var object = try #require(JSONSerialization.jsonObject(with: windowsFixture()) as? [String: Any])
    var notes = try #require(object["Notes"] as? [[String: Any]])
    var bad = notes[0]
    bad["Id"] = UUID().uuidString
    if field == "Due" {
        var reminder = try #require(bad["Reminder"] as? [String: Any])
        reminder["Due"] = "2026-02-30T09:00:00+08:00"; bad["Reminder"] = reminder
    } else { bad["DeletedAt"] = "2026-02-30T09:00:00+08:00" }
    notes.append(bad); object["Notes"] = notes
    let bytes = try JSONSerialization.data(withJSONObject: object)
    await #expect(throws: TransferError.invalidDocument) {
        try await DataTransferService(repository: repository).importWindows(bytes, backupURL: file,
            settings: TransferSettings(), timeZone: .gmt, fallbackTitle: "Reminder", now: transferNow)
    }
    #expect(try await repository.transferSnapshot() == before)
    #expect(try await repository.pendingOutbox() == journal)
    #expect(try Data(contentsOf: file) == Data("previous backup".utf8))
}
