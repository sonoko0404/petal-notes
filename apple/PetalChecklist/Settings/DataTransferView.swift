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
                        timeZone: .current, fallbackTitle: String(localized: "Imported reminder"), now: .now)
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
        GroupBox("Data Transfer") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Daily reminders use this Mac’s time zone at import. A JSON backup is saved before importing.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Import Windows Notes…") { importWindows() }.accessibilityIdentifier("transfer.importWindows")
                    Button("Export JSON Backup…") {
                        if let url = saveJSON(title: String(localized: "Export JSON Backup…"), name: "Petal Backup.json") {
                            Task { await model.run(.backup(url)) }
                        }
                    }.accessibilityIdentifier("transfer.exportJSON")
                }
                HStack {
                    Button("Replace from Backup…") { restoreURL = openJSON() }.accessibilityIdentifier("transfer.restoreJSON")
                    Button("Export Markdown Folder…") {
                        let panel = NSOpenPanel()
                        panel.title = String(localized: "Export Markdown Folder…")
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { Task { await model.run(.markdown(url)) } }
                    }.accessibilityIdentifier("transfer.exportMarkdown")
                }
                Text("Markdown creates a new Petal Markdown Export folder inside the directory you choose.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.isRunning { ProgressView("Transferring Data…").accessibilityIdentifier("transfer.progress") }
                if model.failed {
                    Text("Unable to transfer data. Check the file and destination, then retry. Markdown needs a new folder.")
                        .foregroundStyle(.red).accessibilityIdentifier("transfer.error")
                    Button("Retry") { Task { await model.retry() } }.accessibilityIdentifier("transfer.retry")
                }
                if model.succeeded { Text("Transfer complete.").accessibilityIdentifier("transfer.success") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.isRunning)
        }
        .confirmationDialog("Replace Current Data?", isPresented: Binding(get: { restoreURL != nil }, set: { if !$0 { restoreURL = nil } }), titleVisibility: .visible) {
            Button("Replace Data", role: .destructive) {
                if let url = restoreURL { Task { await model.run(.restore(url)) } }
                restoreURL = nil
            }
        } message: {
            Text("This replaces all cards, lines, and reminder sound settings with the backup. Changes sync to iCloud when enabled. Export a backup first if you want to keep the current data.")
        }
    }

    private func importWindows() {
        guard let source = openJSON(), let backup = saveJSON(title: String(localized: "Save Backup Before Import"), name: "Petal Before Import.json") else { return }
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
