import Foundation
import SwiftUI
import Observation
import PetalCore
import PetalPersistence
import PetalSync

@MainActor @Observable
final class SyncSettingsModel {
    private let repository: any PetalSyncRepository
    let coordinator: CloudSyncCoordinator
    private(set) var enabled = true
    private(set) var state: SyncState = .offline
    private(set) var conflicts: [ConflictArtifact] = []
    private(set) var operationFailed = false
    var isResetRequested = false
    init(repository: any PetalSyncRepository, coordinator: CloudSyncCoordinator) {
        self.repository = repository; self.coordinator = coordinator
    }
    func load() async {
        do {
            let snapshot = try await repository.syncSnapshot()
            enabled = snapshot.enabled; state = snapshot.state
            conflicts += try await repository.takeUnpresentedConflicts(now: .now)
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
            operationFailed = false
        } catch { operationFailed = true }
    }
    func sync(_ reason: SyncReason) async {
        if enabled { state = .syncing }
        await coordinator.sync(reason: reason)
        do {
            let snapshot = try await repository.syncSnapshot()
            enabled = snapshot.enabled; state = snapshot.state
        } catch { operationFailed = true }
    }
    func requestReset() { isResetRequested = true }
    func dismissConflicts() { conflicts = [] }
    var statusKey: LocalizedStringKey {
        if !enabled { return "iCloud Sync Is Off" }
        switch state {
        case .syncing: return "Syncing with iCloud"
        case .synced: return "Synced with iCloud"
        case .offline: return "Offline — Changes Are Saved Locally"
        case .failed(.quotaExceeded): return "iCloud Storage Is Full"
        case .failed(.authenticationRequired): return "Sign In to iCloud in System Settings"
        case .failed: return "Unable to Sync. Try Again."
        }
    }
}

struct SyncSettingsView: View {
    @Bindable var model: SyncSettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("iCloud Sync", isOn: Binding(get: { model.enabled }, set: { value in Task { await model.setEnabled(value) } }))
                .accessibilityIdentifier("settings.syncEnabled")
            Text(model.statusKey).accessibilityIdentifier("settings.syncStatus")
            Button("Sync Now") { Task { await model.sync(.userRequested) } }
                .disabled(!model.enabled).accessibilityIdentifier("settings.syncNow")
            if model.operationFailed { Text("Unable to Sync. Try Again.").foregroundStyle(.red) }
            if !model.conflicts.isEmpty {
                Text("Conflicting edits were saved for 30 days.")
                ForEach(model.conflicts) { artifact in
                    Text(conflictText(artifact)).textSelection(.enabled)
                }
                Button("Dismiss Conflict Notice") { model.dismissConflicts() }
            }
            Button("Delete All Data…", role: .destructive) { model.requestReset() }
                .accessibilityIdentifier("settings.resetEntry")
        }
        .task { await model.load() }
        .sheet(isPresented: $model.isResetRequested) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Delete All Data").font(.headline)
                Text("Deleting all data creates an empty Inbox on your devices. Cloud changes finish when iCloud is available.")
                // Task 11 owns the final destructive confirmation flow. This
                // entry intentionally has no deletion side effect.
                Button("Close") { model.isResetRequested = false }.keyboardShortcut(.cancelAction)
            }.padding().frame(width: 420)
        }
    }
    private func conflictText(_ artifact: ConflictArtifact) -> String {
        if let line = try? JSONDecoder().decode(CardLine.self, from: artifact.losingPayload) { return line.text }
        if let card = try? JSONDecoder().decode(Card.self, from: artifact.losingPayload) { return card.title }
        return String(localized: "A conflicting edit was preserved.")
    }
}
