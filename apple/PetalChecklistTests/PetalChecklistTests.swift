import XCTest
import PetalActions
import PetalTestSupport
import PetalPersistence
import PetalImportExport
@testable import PetalChecklist

final class PetalChecklistTests: XCTestCase {
    func testBundleLoads() {}

    @MainActor func testTransferFailureCanRetryAndProducesBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Backup.json")
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        try await repository.bootstrap(now: .now)
        let model = DataTransferModel(repository: repository,
            settings: { TransferSettings(notificationSoundEnabled: true) }, applySettings: { _ in })
        await model.run(.backup(file))
        XCTAssertTrue(model.failed)
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.succeeded)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await model.retry()
        XCTAssertFalse(model.failed)
        XCTAssertTrue(model.succeeded)
        XCTAssertFalse(model.isRunning)
        let backup = try PetalBackupCodec.decode(Data(contentsOf: file))
        XCTAssertEqual(backup.snapshot.cards.map(\.title), ["Inbox"])
        XCTAssertTrue(backup.settings.notificationSoundEnabled)
    }

    @MainActor func testMarkdownTransferUsesGrantedDirectoryAsParentOfAllOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selected = root.appendingPathComponent("User-selected directory")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SwiftDataPetalRepository(container: try ModelContainerFactory.makeInMemory())
        try await repository.bootstrap(now: .now)
        let model = DataTransferModel(repository: repository, settings: { TransferSettings() }, applySettings: { _ in })
        await model.run(.markdown(selected))
        XCTAssertTrue(model.succeeded)
        XCTAssertFalse(model.failed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["User-selected directory"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: selected.path), ["Petal Markdown Export"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: selected.appendingPathComponent("Petal Markdown Export").path).count, 1)
    }
}
