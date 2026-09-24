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
}
