import Foundation
import SwiftUI
import Observation
import PetalCore
import PetalPersistence
import PetalSync

enum PetalErrorCopy {
    static func message(_ error: Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription { return description }
        return String(localized: "ui.storage_retry")
    }
}

struct FeedbackInfo {
    let version: String
    let build: String
    let systemVersion: String
    let architecture: String
    var body: String { String.localizedStringWithFormat(String(localized: "ui.feedback_metadata"), version, build, systemVersion, architecture) }
    func mailURL(email: String) -> URL? {
        guard email.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"; components.path = email
        components.queryItems = [.init(name: "subject", value: String(localized: "ui.feedback.aac77d")), .init(name: "body", value: body)]
        return components.url
    }
    static var current: Self {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return Self(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture)
    }
}

@MainActor @Observable
final class ResetSettingsModel {
    let productName: String
    var confirmation = ""
    private(set) var failed = false
    private(set) var succeeded = false
    private(set) var isRunning = false
    private let reset: () async throws -> Bool
    private let retryEffects: () async throws -> Void
    private var needsEffects = false
    private let defaults: UserDefaults?
    private let onFinished: () async -> Void
    init(productName: String, defaults: UserDefaults? = nil, reset: @escaping () async throws -> Bool,
         retryEffects: @escaping () async throws -> Void, onFinished: @escaping () async -> Void = {}) {
        self.productName = productName; self.reset = reset; self.retryEffects = retryEffects
        self.defaults = defaults
        self.onFinished = onFinished
        needsEffects = defaults?.bool(forKey: "reset.effectsPending") ?? false
        failed = needsEffects
    }
    var canSubmit: Bool { confirmation == productName && !isRunning && !succeeded }
    func beginConfirmation() {
        guard !isRunning else { return }
        confirmation = ""; succeeded = false
    }
    func submit() async {
        guard canSubmit else { return }
        isRunning = true; failed = false
        defer { isRunning = false }
        do {
            if needsEffects { try await retryEffects(); needsEffects = false }
            else { needsEffects = try await !reset() }
            defaults?.set(needsEffects, forKey: "reset.effectsPending")
            failed = needsEffects; succeeded = !needsEffects
            if succeeded { await onFinished() }
        } catch { failed = true }
    }
}

@MainActor @Observable
final class SyncSettingsModel {
    private let repository: any PetalSyncRepository
    let coordinator: CloudSyncCoordinator
    private(set) var enabled = true
    private(set) var state: SyncState = .offline
    private(set) var conflicts: [ConflictArtifact] = []
    private(set) var unpresentedConflictCount = 0
    private(set) var operationFailed = false
    var isResetRequested = false
    init(repository: any PetalSyncRepository, coordinator: CloudSyncCoordinator) {
        self.repository = repository; self.coordinator = coordinator
    }
    func load(now: Date = .now) async {
        do {
            let snapshot = try await repository.syncSnapshot()
            enabled = snapshot.enabled; state = snapshot.state
            try await refreshConflicts(now: now, replacingNoticeCount: true)
            operationFailed = false
        } catch { operationFailed = true }
    }
    func startObserving() async {
        if let snapshot = try? await repository.syncSnapshot() { enabled = snapshot.enabled; state = snapshot.state }
        await coordinator.observeState { [weak self] value in await self?.receive(value) }
    }
    private func receive(_ value: SyncState) { state = value }
    func setEnabled(_ value: Bool) async {
        do {
            try await coordinator.setEnabled(value)
            let snapshot = try await repository.syncSnapshot()
            enabled = snapshot.enabled; state = snapshot.state
            try await refreshConflicts(now: .now, replacingNoticeCount: false)
            operationFailed = false
        } catch { operationFailed = true }
    }
    func sync(_ reason: SyncReason) async {
        if enabled { state = .syncing }
        await coordinator.sync(reason: reason)
        do {
            let snapshot = try await repository.syncSnapshot()
            enabled = snapshot.enabled; state = snapshot.state
            try await refreshConflicts(now: .now, replacingNoticeCount: false)
            operationFailed = false
        } catch { operationFailed = true }
    }
    func requestReset() { isResetRequested = true }
    func dismissConflictNotice() { unpresentedConflictCount = 0 }
    private func refreshConflicts(now: Date, replacingNoticeCount: Bool) async throws {
        let newlyUnpresented = try await repository.takeUnpresentedConflicts(now: now).count
        unpresentedConflictCount = replacingNoticeCount
            ? newlyUnpresented
            : unpresentedConflictCount + newlyUnpresented
        let allConflicts = try await repository.conflicts()
        conflicts = allConflicts.filter { $0.expiresAt > now }
    }
    func recover(_ id: UUID, now: Date = .now) async -> CardID? {
        do {
            let cardID = try await repository.recoverConflict(id: id, now: now)
            let allConflicts = try await repository.conflicts()
            conflicts = allConflicts.filter { $0.expiresAt > now }
            operationFailed = false
            return cardID
        } catch {
            operationFailed = true
            return nil
        }
    }
    var statusKey: LocalizedStringKey {
        if !enabled { return "ui.icloud_sync_is_off.ef869d" }
        switch state {
        case .syncing: return "ui.syncing_with_icloud.c9c05f"
        case .synced: return "ui.synced_with_icloud.c52146"
        case .offline: return "ui.offline_changes_are_saved_locally.f35944"
        case .failed(.quotaExceeded): return "ui.icloud_storage_is_full.c000d8"
        case .failed(.authenticationRequired): return "ui.sign_in_to_icloud_in_system_settings.1fe2fe"
        case .failed: return "ui.unable_to_sync_try_again.33e914"
        }
    }
}

struct SyncSettingsView: View {
    @Bindable var model: SyncSettingsModel
    var resetModel: ResetSettingsModel?
    var onOpenRecoveredCard: (CardID) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("ui.icloud_sync.f18c29", isOn: Binding(get: { model.enabled }, set: { value in Task { await model.setEnabled(value) } }))
                .accessibilityIdentifier("settings.syncEnabled")
            Text(model.statusKey).accessibilityIdentifier("settings.syncStatus")
            Button("ui.sync_now.b5060f") { Task { await model.sync(.userRequested) } }
                .disabled(!model.enabled).accessibilityIdentifier("settings.syncNow")
            if model.operationFailed { Text("ui.unable_to_sync_try_again.33e914").foregroundStyle(.red) }
            if model.unpresentedConflictCount > 0 {
                Text("ui.conflicting_edits_were_saved_for_30_days.801609")
                Button("ui.dismiss_conflict_notice.90003b") { model.dismissConflictNotice() }
                    .accessibilityIdentifier("settings.dismissConflictNotice")
            }
            if !model.conflicts.isEmpty {
                Text("ui.recoverable_conflict_copies.4f113d").font(.headline)
                Text("ui.conflict_copy_explanation.0d9410").foregroundStyle(.secondary)
                ForEach(model.conflicts) { artifact in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conflictText(artifact)).textSelection(.enabled)
                        LabeledContent("ui.conflict_captured.7e116b") {
                            Text(artifact.capturedAt, style: .date)
                        }
                        LabeledContent("ui.conflict_expires.5d12ae") {
                            Text(artifact.expiresAt, style: .date)
                        }
                        if let recoveredCardID = artifact.recoveredCardID {
                            Label("ui.recovered_copy_ready.8b1d02", systemImage: "checkmark.circle")
                                .accessibilityIdentifier("settings.conflictRecovered.\(artifact.id)")
                            Button("ui.open_recovered_copy.604c37") { onOpenRecoveredCard(recoveredCardID) }
                                .accessibilityIdentifier("settings.openRecoveredConflict.\(artifact.id)")
                        } else {
                            Button("ui.recover_copy.5f2a11") {
                                Task {
                                    if let recoveredCardID = await model.recover(artifact.id) {
                                        onOpenRecoveredCard(recoveredCardID)
                                    }
                                }
                            }
                                .accessibilityIdentifier("settings.recoverConflict.\(artifact.id)")
                        }
                    }
                }
            }
            Button("ui.delete_all_data.b963c2", role: .destructive) { resetModel?.beginConfirmation(); model.requestReset() }
                .accessibilityIdentifier("settings.resetEntry")
        }
        .task { await model.load() }
        .sheet(isPresented: $model.isResetRequested) {
            VStack(alignment: .leading, spacing: 16) {
                Text("ui.delete_all_data.96d59c").font(.headline)
                Text("ui.deleting_all_data_creates_an_empty_inbox_on_your_device.049439")
                if let resetModel { ResetConfirmationView(model: resetModel) }
                Button("ui.close.7d9eb7") { model.isResetRequested = false }.keyboardShortcut(.cancelAction)
            }.padding().frame(width: 420)
        }
    }
    private func conflictText(_ artifact: ConflictArtifact) -> String {
        if let line = try? JSONDecoder().decode(CardLine.self, from: artifact.losingPayload) { return line.text }
        if let card = try? JSONDecoder().decode(Card.self, from: artifact.losingPayload) { return card.title }
        return String(localized: "ui.a_conflicting_edit_was_preserved.6c3ef7")
    }
}

struct ResetConfirmationView: View {
    @Bindable var model: ResetSettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ui.this_deletes_all_petal_cards_and_reminders_on_this_mac_.caf85e")
            Text("ui.confirm_product \(model.productName)")
            TextField("ui.product_name.bfa93e", text: $model.confirmation).accessibilityIdentifier("settings.resetConfirmation")
            if model.failed { Text("ui.deletion_needs_attention_retry_to_finish_local_cleanup_.fe156c").foregroundStyle(.red) }
            if model.succeeded { Text("ui.local_data_deleted_one_empty_inbox_remains_check_icloud.7766ed") }
            Button(model.failed ? "ui.retry.942087" : "ui.delete_all_data.96d59c", role: .destructive) { Task { await model.submit() } }
                .disabled(!model.canSubmit).accessibilityIdentifier("settings.resetConfirm")
        }.disabled(model.isRunning)
    }
}
