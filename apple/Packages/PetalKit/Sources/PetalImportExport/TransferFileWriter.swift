import Foundation

public enum TransferFileWriter {
    public static func write(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: (any Error)?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { selectedURL in
            do {
                // Foundation owns safe-save replacement resources. Caller-created
                // siblings would exceed an NSSavePanel selected-file grant.
                try data.write(to: selectedURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: selectedURL.path)
                let handle = try FileHandle(forWritingTo: selectedURL)
                do { try handle.synchronize(); try handle.close() }
                catch { try? handle.close(); throw error }
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}
