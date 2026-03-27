import Foundation
import TouchBridgeProtocol

/// A single audit log entry. Never contains nonce values.
public struct AuditEntry: Codable, Sendable {
    public let ts: String
    public let sessionID: String
    public let surface: String
    public let requestingProcess: String
    public let companionDevice: String
    public let deviceID: String
    public let result: String
    public let authType: String
    public let rssi: Int?
    public let latencyMs: Int?

    enum CodingKeys: String, CodingKey {
        case ts
        case sessionID = "session_id"
        case surface
        case requestingProcess = "requesting_process"
        case companionDevice = "companion_device"
        case deviceID = "device_id"
        case result
        case authType = "auth_type"
        case rssi
        case latencyMs = "latency_ms"
    }

    public init(
        sessionID: String,
        surface: String,
        requestingProcess: String = "",
        companionDevice: String = "",
        deviceID: String = "",
        result: String,
        authType: String = "biometric",
        rssi: Int? = nil,
        latencyMs: Int? = nil
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.ts = formatter.string(from: Date())

        self.sessionID = sessionID
        self.surface = surface
        self.requestingProcess = requestingProcess
        self.companionDevice = companionDevice
        self.deviceID = deviceID
        self.result = result
        self.authType = authType
        self.rssi = rssi
        self.latencyMs = latencyMs
    }
}

/// Append-only NDJSON audit log writer.
///
/// Writes to `~/Library/Logs/TouchBridge/touchbridge-YYYY-MM-DD.ndjson`.
/// Thread-safe via `actor` isolation.
public actor AuditLog {
    private let logDirectory: URL
    private let encoder: JSONEncoder

    /// Initialize with a custom log directory (default: ~/Library/Logs/TouchBridge/).
    public init(logDirectory: URL? = nil) {
        if let dir = logDirectory {
            self.logDirectory = dir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.logDirectory = home
                .appendingPathComponent("Library/Logs/TouchBridge", isDirectory: true)
        }
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    /// Log an audit entry. Fire-and-forget from the caller's perspective.
    public func log(_ entry: AuditEntry) {
        do {
            try ensureDirectoryExists()
            let fileURL = logFileURL()
            let data = try encoder.encode(entry)

            guard var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: fileURL, options: .atomic)
            }
        } catch {
            // Audit log failures must not crash the daemon.
            // In production, this would go to OSLog as a fallback.
        }
    }

    /// Read all entries from today's log file (for testing / audit viewer).
    public func readEntries() throws -> [AuditEntry] {
        let fileURL = logFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return content
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(AuditEntry.self, from: Data(line.utf8))
            }
    }

    /// Path to today's log file.
    public func logFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let datePart = formatter.string(from: Date())
        return logDirectory.appendingPathComponent("touchbridge-\(datePart).ndjson")
    }

    // MARK: - Private

    private func ensureDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logDirectory.path) {
            try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        }
    }
}
