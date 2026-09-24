import Foundation
import Darwin
import AppKit
import SwiftUI

struct DiagnosticVersion: Codable, Equatable, Sendable {
    let major: UInt16
    let minor: UInt16
    let patch: UInt16
    let build: UInt16
}
enum DiagnosticSubsystem: String, Codable, Sendable { case storage, sync, notifications, transfer }
enum DiagnosticErrorCode: String, Codable, Sendable { case openFailed, saveFailed, unavailable }
enum DiagnosticSyncState: String, Codable, Sendable { case unknown, disabled, idle, syncing, offline, failed }
struct DiagnosticEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let subsystem: DiagnosticSubsystem
    let errorCode: DiagnosticErrorCode
    let syncState: DiagnosticSyncState
    let appVersion: DiagnosticVersion
    let osVersion: DiagnosticVersion
    static func current(subsystem: DiagnosticSubsystem, errorCode: DiagnosticErrorCode,
                        syncState: DiagnosticSyncState) -> DiagnosticEvent {
        let app = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")
            .split(separator: ".").compactMap { UInt16($0) }
        let build = UInt16(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticEvent(timestamp: .now, subsystem: subsystem, errorCode: errorCode, syncState: syncState,
            appVersion: DiagnosticVersion(major: app.first ?? 0, minor: app.count > 1 ? app[1] : 0,
                patch: app.count > 2 ? app[2] : 0, build: build),
            osVersion: DiagnosticVersion(major: UInt16(clamping: os.majorVersion), minor: UInt16(clamping: os.minorVersion),
                patch: UInt16(clamping: os.patchVersion), build: 0))
    }
}

struct DiagnosticsExportView: View {
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading) {
            Text("ui.diagnostics_description").font(.caption).foregroundStyle(.secondary)
            Button("ui.export_diagnostics") {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "Petal-diagnostics.json"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                Task {
                    do {
                        let log = try Diagnostics.local()
                        let data = try await log.export()
                        let granted = url.startAccessingSecurityScopedResource()
                        defer { if granted { url.stopAccessingSecurityScopedResource() } }
                        try data.write(to: url, options: .atomic)
                        failed = false
                    } catch { failed = true }
                }
            }.accessibilityIdentifier("settings.exportDiagnostics")
            if failed { Text("ui.diagnostics_export_failed").foregroundStyle(.red) }
        }
    }
}
actor Diagnostics {
    private let directory: URL
    private let clock: @Sendable () -> Date
    private static let byteLimit = 262144
    private static let eventLimit = 1024

    /// App-private caches, outside the shared store, backup codec and CloudKit mapping.
    static func local() throws -> Diagnostics {
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("PetalDiagnostics", isDirectory: true)
        return try Diagnostics(directory: directory)
    }

    init(directory: URL, clock: @escaping @Sendable () -> Date = { .now }) throws {
        self.directory = directory
        self.clock = clock
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func record(_ event: DiagnosticEvent) throws {
        try locked {
            let now = clock()
            var events = read(now: now)
            if Self.isCurrent(event, now: now) { events.append(event) }
            try persist(events)
        }
    }

    /// Called only by an explicit export action; never uploads or opens another app.
    func export() throws -> Data {
        try locked { try persist(read(now: clock())) }
    }
    func prune() throws { _ = try locked { try persist(read(now: clock())) } }

    private static func isCurrent(_ event: DiagnosticEvent, now: Date) -> Bool {
        let age = now.timeIntervalSince(event.timestamp)
        return age.isFinite && age >= 0 && age < 604800
    }

    private func read(now: Date) -> [DiagnosticEvent] {
        let url = directory.appendingPathComponent("events.json")
        // Bound the read itself, including corrupt or maliciously oversized files.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.byteLimit + 1), data.count <= Self.byteLimit,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= Self.eventLimit else { return [] }
        let keys: Set<String> = ["timestamp", "subsystem", "errorCode", "syncState", "appVersion", "osVersion"]
        let versionKeys: Set<String> = ["major", "minor", "patch", "build"]
        guard rows.allSatisfy({ row in
            Set(row.keys) == keys && ["appVersion", "osVersion"].allSatisfy {
                guard let version = row[$0] as? [String: Any] else { return false }
                return Set(version.keys) == versionKeys
            }
        }), let events = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) else { return [] }
        return events.filter { Self.isCurrent($0, now: now) }
    }

    @discardableResult private func persist(_ events: [DiagnosticEvent]) throws -> Data {
        var bounded = Array(events.sorted { $0.timestamp < $1.timestamp }.suffix(Self.eventLimit))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(bounded)
        while bytes.count > Self.byteLimit && !bounded.isEmpty {
            bounded.removeFirst()
            bytes = try encoder.encode(bounded)
        }
        let url = directory.appendingPathComponent("events.json")
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return bytes
    }

    /// Actor isolation serializes one handle; the file lock protects independent handles/processes.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(directory.appendingPathComponent("events.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
