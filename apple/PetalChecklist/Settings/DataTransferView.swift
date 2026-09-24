import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import PetalImportExport
import PetalPersistence
import PetalActions

enum DataTransferOperation {
    case windows(source: URL, backup: URL)
    case backup(URL)
    case restore(URL)
    case markdown(URL)
}

@MainActor @Observable
final class DataTransferModel {
    private let service: DataTransferService
    private let settings: () -> TransferSettings
    private let applySettings: (TransferSettings) -> Void
    private let prepare: () async -> Bool
    private let finished: () async -> Void
    private(set) var isRunning = false
    private(set) var failed = false
    private(set) var succeeded = false
    private var retryOperation: DataTransferOperation?
    init(repository: any PetalTransferRepository,
         settings: @escaping () -> TransferSettings,
         applySettings: @escaping (TransferSettings) -> Void,
         prepare: @escaping () async -> Bool = { true },
         finished: @escaping () async -> Void = {}) {
        service = DataTransferService(repository: repository)
        self.settings = settings; self.applySettings = applySettings
        self.prepare = prepare; self.finished = finished
    }
    func run(_ operation: DataTransferOperation) async {
        guard !isRunning else { return }
        isRunning = true; failed = false; succeeded = false; retryOperation = operation
        defer { isRunning = false }
        guard await prepare() else { failed = true; return }
        do {
            switch operation {
            case .windows(let source, let backup):
                guard source.resolvingSymlinksInPath().standardizedFileURL != backup.resolvingSymlinksInPath().standardizedFileURL else {
                    throw TransferError.invalidDocument
                }
                try await SecurityScopedTransferURLs.withAccess([source, backup]) {
                    let data = try await Task.detached { try Data(contentsOf: source) }.value
                    _ = try await service.importWindows(data, backupURL: backup, settings: settings(),
                        timeZone: .current, fallbackTitle: String(localized: "ui.imported_reminder.a34a16"), now: .now)
                }
            case .backup(let url):
                try await SecurityScopedTransferURLs.withAccess([url]) { try await service.exportBackup(to: url, settings: settings()) }
            case .restore(let url):
                try await SecurityScopedTransferURLs.withAccess([url]) {
                    let data = try await Task.detached { try Data(contentsOf: url) }.value
                    let restored = try await service.restore(data, now: .now)
                    applySettings(restored)
                }
            case .markdown(let url):
                try await SecurityScopedTransferURLs.withAccess([url]) {
                    try await service.exportMarkdown(to: url, languageCode: Locale.current.language.languageCode?.identifier ?? "en")
                }
            }
            succeeded = true; retryOperation = nil
        } catch { failed = true }
        await finished()
    }
    func retry() async { if let retryOperation { await run(retryOperation) } }
}

/// Hold user-selected file grants across all asynchronous reads/writes and balance them on every exit.
@MainActor enum SecurityScopedTransferURLs {
    static func withAccess(_ urls: [URL], operation: () async throws -> Void) async rethrows {
        let granted = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in granted { url.stopAccessingSecurityScopedResource() } }
        try await operation()
    }
}

struct DataTransferView: View {
    @Bindable var model: DataTransferModel
    @State private var restoreURL: URL?
    var body: some View {
        GroupBox("ui.data_transfer.786b69") {
            VStack(alignment: .leading, spacing: 8) {
                Text("ui.daily_reminders_use_this_mac_s_time_zone_at_import_a_js.773c69")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("ui.import_windows_notes.904fb3") { importWindows() }.accessibilityIdentifier("transfer.importWindows")
                    Button("ui.export_json_backup.71df65") {
                        if let url = saveJSON(title: String(localized: "ui.export_json_backup.71df65"), name: String(localized: "ui.petal_backup_json.467893")) {
                            Task { await model.run(.backup(url)) }
                        }
                    }.accessibilityIdentifier("transfer.exportJSON")
                }
                HStack {
                    Button("ui.replace_from_backup.49de35") { restoreURL = openJSON() }.accessibilityIdentifier("transfer.restoreJSON")
                    Button("ui.export_markdown_folder.d04c7f") {
                        let panel = NSOpenPanel()
                        panel.title = String(localized: "ui.export_markdown_folder.d04c7f")
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { Task { await model.run(.markdown(url)) } }
                    }.accessibilityIdentifier("transfer.exportMarkdown")
                }
                Text("ui.markdown_creates_a_new_petal_markdown_export_folder_ins.47f673")
                    .font(.caption).foregroundStyle(.secondary)
                if model.isRunning { ProgressView("ui.transferring_data.721cf4").accessibilityIdentifier("transfer.progress") }
                if model.failed {
                    Text("ui.unable_to_transfer_data_check_the_file_and_destination_.631c5f")
                        .foregroundStyle(.red).accessibilityIdentifier("transfer.error")
                    Button("ui.retry.942087") { Task { await model.retry() } }.accessibilityIdentifier("transfer.retry")
                }
                if model.succeeded { Text("ui.transfer_complete.a4a45d").accessibilityIdentifier("transfer.success") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.isRunning)
        }
        .confirmationDialog("ui.replace_current_data.7cef1a", isPresented: Binding(get: { restoreURL != nil }, set: { if !$0 { restoreURL = nil } }), titleVisibility: .visible) {
            Button("ui.replace_data.6c8f89", role: .destructive) {
                if let url = restoreURL { Task { await model.run(.restore(url)) } }
                restoreURL = nil
            }
        } message: {
            Text("ui.this_replaces_all_cards_lines_and_reminder_sound_settin.9dd1e0")
        }
    }

    private func importWindows() {
        guard let source = openJSON(), let backup = saveJSON(title: String(localized: "ui.save_backup_before_import.fa9d80"), name: String(localized: "ui.petal_before_import_json.e40d37")) else { return }
        Task { await model.run(.windows(source: source, backup: backup)) }
    }
    private func openJSON() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func saveJSON(title: String, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title; panel.nameFieldStringValue = name; panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
