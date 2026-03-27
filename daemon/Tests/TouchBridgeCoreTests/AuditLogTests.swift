import Testing
import Foundation
@testable import TouchBridgeCore

/// Create a temporary directory for each test's audit log.
private func makeTempLogDir() -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("touchbridge-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

private func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Tests

@Test func logWritesEntry() async throws {
    let dir = makeTempLogDir()
    defer { cleanup(dir) }

    let log = AuditLog(logDirectory: dir)

    let entry = AuditEntry(
        sessionID: "sess-001",
        surface: "pam_sudo",
        requestingProcess: "sudo",
        companionDevice: "Test iPhone",
        deviceID: "device-abc",
        result: "VERIFIED",
        authType: "biometric",
        rssi: -58,
        latencyMs: 1240
    )

    await log.log(entry)

    let entries = try await log.readEntries()
    #expect(entries.count == 1)
    #expect(entries[0].sessionID == "sess-001")
    #expect(entries[0].surface == "pam_sudo")
    #expect(entries[0].result == "VERIFIED")
    #expect(entries[0].rssi == -58)
    #expect(entries[0].latencyMs == 1240)
}

@Test func logNeverContainsNonce() async throws {
    let dir = makeTempLogDir()
    defer { cleanup(dir) }

    let log = AuditLog(logDirectory: dir)

    let entry = AuditEntry(
        sessionID: "sess-002",
        surface: "pam_sudo",
        result: "VERIFIED"
    )

    await log.log(entry)

    // Read the raw file content and verify no "nonce" key exists
    let fileURL = await log.logFileURL()
    let content = try String(contentsOf: fileURL, encoding: .utf8)

    #expect(!content.contains("\"nonce\""))
    // Also verify the entry struct has no nonce field by checking all keys
    #expect(content.contains("\"session_id\""))
    #expect(content.contains("\"result\""))
}

@Test func multipleEntriesAppend() async throws {
    let dir = makeTempLogDir()
    defer { cleanup(dir) }

    let log = AuditLog(logDirectory: dir)

    for i in 0..<3 {
        let entry = AuditEntry(
            sessionID: "sess-\(i)",
            surface: "pam_sudo",
            result: i == 0 ? "VERIFIED" : "FAILED_TIMEOUT"
        )
        await log.log(entry)
    }

    let entries = try await log.readEntries()
    #expect(entries.count == 3)
    #expect(entries[0].sessionID == "sess-0")
    #expect(entries[0].result == "VERIFIED")
    #expect(entries[1].result == "FAILED_TIMEOUT")
    #expect(entries[2].sessionID == "sess-2")
}

@Test func logCreatesDirectoryIfMissing() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("touchbridge-test-\(UUID().uuidString)/nested/deep", isDirectory: true)
    let parentDir = dir.deletingLastPathComponent().deletingLastPathComponent()
    defer { cleanup(parentDir) }

    let log = AuditLog(logDirectory: dir)

    let entry = AuditEntry(
        sessionID: "sess-auto",
        surface: "pam_sudo",
        result: "VERIFIED"
    )

    await log.log(entry)

    let entries = try await log.readEntries()
    #expect(entries.count == 1)
}

@Test func readEntriesReturnsEmptyForMissingFile() async throws {
    let dir = makeTempLogDir()
    defer { cleanup(dir) }

    let log = AuditLog(logDirectory: dir)
    let entries = try await log.readEntries()
    #expect(entries.isEmpty)
}

@Test func entryContainsISO8601Timestamp() async throws {
    let dir = makeTempLogDir()
    defer { cleanup(dir) }

    let log = AuditLog(logDirectory: dir)

    let entry = AuditEntry(
        sessionID: "sess-ts",
        surface: "pam_sudo",
        result: "VERIFIED"
    )

    await log.log(entry)

    let entries = try await log.readEntries()
    #expect(entries.count == 1)
    // ISO 8601 format includes "T" and "Z"
    #expect(entries[0].ts.contains("T"))
    #expect(entries[0].ts.contains("Z"))
}

@Test func allResultValuesLoggable() async throws {
    let dir = makeTempLogDir()
    defer { cleanup(dir) }

    let log = AuditLog(logDirectory: dir)

    let results = ["VERIFIED", "FAILED_BIOMETRIC", "FAILED_TIMEOUT",
                   "FAILED_REPLAY", "FAILED_SIGNATURE", "FAILED_NO_DEVICE"]

    for result in results {
        let entry = AuditEntry(
            sessionID: "sess-\(result)",
            surface: "pam_sudo",
            result: result
        )
        await log.log(entry)
    }

    let entries = try await log.readEntries()
    #expect(entries.count == results.count)
    #expect(Set(entries.map(\.result)) == Set(results))
}
