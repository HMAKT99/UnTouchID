import Foundation
import OSLog

/// Persistent daemon configuration stored in
/// `~/Library/Application Support/TouchBridge/config.json`.
///
/// The most important field is `serviceUUID` — a UUID generated once at first run
/// and never changed. This UUID is unique to this Mac and is used as the BLE
/// service UUID, ensuring that only phones paired with *this* Mac connect to it.
/// Without a unique service UUID every TouchBridge phone in the area would
/// connect to every TouchBridge Mac (they all share the same protocol-level UUID).
public struct DaemonConfig: Sendable {
    /// BLE service UUID unique to this Mac.
    public let serviceUUID: String

    private static let logger = Logger(subsystem: "dev.touchbridge", category: "DaemonConfig")
    private static let filename = "config.json"

    private struct Stored: Codable {
        let serviceUUID: String
    }

    /// Load existing config or create a new one with a fresh service UUID.
    /// Always succeeds — falls back to the shared constant if the config
    /// directory is somehow unwritable (e.g. sandboxed test environment).
    public static func load() -> DaemonConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/Library/Application Support/TouchBridge"
        let path = "\(dir)/\(filename)"

        if let data = FileManager.default.contents(atPath: path),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           !stored.serviceUUID.isEmpty {
            logger.info("Loaded service UUID: \(stored.serviceUUID)")
            return DaemonConfig(serviceUUID: stored.serviceUUID)
        }

        let newUUID = UUID().uuidString
        logger.info("Generating new service UUID: \(newUUID)")

        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: nil
            )
            let data = try JSONEncoder().encode(Stored(serviceUUID: newUUID))
            FileManager.default.createFile(atPath: path, contents: data, attributes: [
                .posixPermissions: 0o600
            ])
        } catch {
            logger.error("Failed to persist config: \(error.localizedDescription) — using ephemeral UUID")
        }

        return DaemonConfig(serviceUUID: newUUID)
    }

    private init(serviceUUID: String) {
        self.serviceUUID = serviceUUID
    }
}
