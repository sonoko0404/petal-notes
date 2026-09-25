import Foundation
import PetalPersistence

public actor DataTransferService {
    private let repository: any PetalTransferRepository
    public init(repository: any PetalTransferRepository) { self.repository = repository }
    public func exportBackup(to url: URL, settings: TransferSettings) async throws {
        let snapshot = try await repository.transferSnapshot()
        try TransferFileWriter.write(PetalBackupCodec.encode(PetalBackup(snapshot: snapshot, settings: settings)), to: url)
    }
    /// Explicit replacement. Device-local notification preference is applied by the App only after commit.
    public func restore(_ data: Data, now: Date) async throws -> TransferSettings {
        let backup = try PetalBackupCodec.decode(data)
        try await repository.replaceUserData(backup.snapshot, now: now)
        return backup.settings
    }
    public func exportMarkdown(to url: URL, languageCode: String) async throws {
        try MarkdownExporter.write(await repository.transferSnapshot(), to: url, languageCode: languageCode)
    }
    public func importWindows(_ data: Data, backupURL: URL, settings: TransferSettings,
        timeZone: TimeZone, fallbackTitle: String, now: Date) async throws -> Int {
        let entries = try WindowsNotesImporter.decode(data, now: now, timeZone: timeZone, fallbackTitle: fallbackTitle)
        return try await repository.importCards(entries, now: now) { snapshot in
            let bytes = try PetalBackupCodec.encode(PetalBackup(snapshot: snapshot, settings: settings))
            try TransferFileWriter.write(bytes, to: backupURL)
        }
    }
}
