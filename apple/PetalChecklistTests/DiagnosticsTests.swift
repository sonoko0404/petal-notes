import XCTest
@testable import PetalChecklist

final class DiagnosticsTests: XCTestCase {
    func testCurrentEventUsesNumericBuildAndOSVersions() throws {
        let value = DiagnosticEvent.current(subsystem: .storage, errorCode: .openFailed, syncState: .failed)
        XCTAssertEqual(value.appVersion, DiagnosticVersion(major: 0, minor: 1, patch: 0, build: 1))
        XCTAssertEqual(value.osVersion.major, UInt16(ProcessInfo.processInfo.operatingSystemVersion.majorVersion))
        XCTAssertEqual(value.subsystem, .storage)
        XCTAssertEqual(value.errorCode, .openFailed)
        XCTAssertEqual(value.syncState, .failed)
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func event(_ time: Date) -> DiagnosticEvent {
        DiagnosticEvent(timestamp: time, subsystem: .storage, errorCode: .openFailed, syncState: .disabled,
            appVersion: DiagnosticVersion(major: 0, minor: 1, patch: 0, build: 1),
            osVersion: DiagnosticVersion(major: 27, minor: 0, patch: 0, build: 0))
    }
    func testClosedSchemaCannotSerializeInjectedContent() async throws {
        let root = try directory()
        let log = try Diagnostics(directory: root, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        try await log.record(event(now))
        let data = try await log.export()
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(array.first).keys), Set(["timestamp", "subsystem", "errorCode", "syncState", "appVersion", "osVersion"]))
        var injected = try XCTUnwrap(array.first)
        injected["message"] = "SECRET title path user-id"
        try JSONSerialization.data(withJSONObject: [injected]).write(to: root.appendingPathComponent("events.json"))
        let recovered = try await log.export()
        XCTAssertEqual(String(decoding: recovered, as: UTF8.self), "[]", "Unknown fields must fail closed, not persist content")
        for key in ["errorCode", "appVersion"] {
            var poisoned = try XCTUnwrap(array.first)
            poisoned[key] = "SECRET title path user-id"
            try JSONSerialization.data(withJSONObject: [poisoned]).write(to: root.appendingPathComponent("events.json"))
            let cleared = try await log.export()
            XCTAssertEqual(String(decoding: cleared, as: UTF8.self), "[]")
        }
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET"))
    }
    func testSevenDayBoundaryAndBoundedAtomicConcurrentWriters() async throws {
        let root = try directory()
        let log = try Diagnostics(directory: root, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        try await log.record(event(now.addingTimeInterval(-604800)))
        try await log.record(event(now.addingTimeInterval(-604799)))
        var data = try await log.export()
        XCTAssertEqual(try JSONDecoder().decode([DiagnosticEvent].self, from: data).count, 1)
        let other = try Diagnostics(directory: root, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        let value = event(now)
        // Below the cap, exact count detects lost updates between independent actors.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 { group.addTask { try await (index.isMultiple(of: 2) ? log : other).record(value) } }
            try await group.waitForAll()
        }
        data = try await log.export()
        XCTAssertEqual(try JSONDecoder().decode([DiagnosticEvent].self, from: data).count, 101)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<1100 { group.addTask { try await (index.isMultiple(of: 2) ? log : other).record(value) } }
            try await group.waitForAll()
        }
        data = try await log.export()
        XCTAssertLessThanOrEqual(data.count, 262144)
        XCTAssertEqual(try JSONDecoder().decode([DiagnosticEvent].self, from: data).count, 1024)
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["events.json", "events.lock"])
    }
    func testCorruptOversizedAndFutureEventsRecoverWithoutExportSideEffects() async throws {
        let root = try directory()
        let log = try Diagnostics(directory: root, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        for bytes in [Data("SECRET broken".utf8), Data(repeating: 65, count: 300000)] {
            try bytes.write(to: root.appendingPathComponent("events.json"))
            try await log.record(event(now))
            let data = try await log.export()
            XCTAssertEqual(try JSONDecoder().decode([DiagnosticEvent].self, from: data).count, 1)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET"))
        }
        try await log.record(event(now.addingTimeInterval(1)))
        let data = try await log.export()
        XCTAssertEqual(try JSONDecoder().decode([DiagnosticEvent].self, from: data).count, 1)
    }
}
