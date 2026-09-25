import XCTest
import PetalActions
import PetalTestSupport
import PetalPersistence
import PetalImportExport
@testable import PetalChecklist

final class PetalChecklistTests: XCTestCase {
    @MainActor func testFeedbackContainsOnlyApprovedMetadataAndEncodesQuery() throws {
        let info = FeedbackInfo(version: "1.0 & test", build: "42", systemVersion: "14.0", architecture: "arm64")
        XCTAssertNil(info.mailURL(email: ""))
        let url = try XCTUnwrap(info.mailURL(email: "support@example.com"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "mailto")
        XCTAssertEqual(parts.path, "support@example.com")
        XCTAssertEqual(parts.queryItems?.map(\.name), ["subject", "body"])
        XCTAssertTrue(["App: 1.0 & test (42)\nmacOS: 14.0\nArchitecture: arm64", "App：1.0 & test（42）\nmacOS：14.0\n架构：arm64"].contains(parts.queryItems?.last?.value ?? ""))
        XCTAssertFalse(url.absoluteString.contains(" & "))
    }

    @MainActor func testResetRequiresProductNameAndRetriesEffectsWithoutDeletingAgain() async throws {
        var resets = 0
        var retries = 0
        var completions = 0
        let model = ResetSettingsModel(productName: "花瓣清单", reset: { resets += 1; return false }, retryEffects: { retries += 1 }, onFinished: { completions += 1 })
        model.confirmation = "Petal"
        await model.submit()
        XCTAssertEqual(resets, 0)
        model.confirmation = "花瓣清单"
        await model.submit()
        XCTAssertEqual(resets, 1)
        XCTAssertTrue(model.failed)
        XCTAssertFalse(model.succeeded)
        XCTAssertEqual(completions, 0)
        await model.submit()
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(retries, 1)
        XCTAssertTrue(model.succeeded)
        XCTAssertEqual(completions, 1)
    }

    func testBundleLoads() {}
    @MainActor func testASecondResetRequiresFreshConfirmation() async throws {
        var resets = 0
        let model = ResetSettingsModel(productName: "Petal", reset: { resets += 1; return true }, retryEffects: {})
        model.confirmation = "Petal"
        await model.submit()
        model.beginConfirmation()
        XCTAssertEqual(model.confirmation, "")
        XCTAssertFalse(model.succeeded)
        XCTAssertFalse(model.canSubmit)
        model.confirmation = "Petal"
        await model.submit()
        XCTAssertEqual(resets, 2)
    }
    @MainActor func testHostedOnboardingResumeAndResetKeepOneInbox() async throws {
        let store = try ModelContainerFactory.makeInMemory()
        let repository = SwiftDataPetalRepository(container: store)
        let seed = OnboardingSeed(inbox: "收集箱", title: "示例", todos: ["添加小组件", "完成待办", "创建卡片"])
        let pending = try await repository.bootstrapOnboarding(seed: seed, now: .now)
        XCTAssertTrue(pending)
        let reopened = SwiftDataPetalRepository(container: store)
        let resumed = try await reopened.bootstrapOnboarding(seed: seed, now: .now)
        XCTAssertTrue(resumed)
        let snapshot = try await reopened.transferSnapshot()
        XCTAssertEqual(snapshot.cards.count, 2)
        XCTAssertEqual(snapshot.lines.count, 3)
        XCTAssertFalse(String(data: try PetalBackupCodec.encode(PetalBackup(snapshot: snapshot, settings: TransferSettings())), encoding: .utf8)?.contains("onboarding") ?? true)
        try await reopened.completeOnboarding()
        try await reopened.deleteAllData(resetGeneration: UUID(), now: .now)
        let pendingAfterReset = try await reopened.bootstrapOnboarding(seed: seed, now: .now)
        let after = try await reopened.transferSnapshot()
        XCTAssertFalse(pendingAfterReset)
        XCTAssertEqual(after.cards.count, 1)
        XCTAssertTrue(after.cards.first?.isInbox == true)
        XCTAssertTrue(after.lines.isEmpty)
    }
    @MainActor func testResetFailureSurvivesSettingsRecreation() async throws {
        let name = "petal.reset-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = ResetSettingsModel(productName: "Petal", defaults: defaults, reset: { false }, retryEffects: {})
        first.confirmation = "Petal"
        await first.submit()
        var resets = 0
        var retries = 0
        let reopened = ResetSettingsModel(productName: "Petal", defaults: defaults, reset: { resets += 1; return true }, retryEffects: { retries += 1 })
        XCTAssertTrue(reopened.failed)
        reopened.confirmation = "Petal"
        await reopened.submit()
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(retries, 1)
    }

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
        XCTAssertTrue([["Inbox"], ["收集箱"]].contains(backup.snapshot.cards.map(\.title)))
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
