import Foundation
import TouchBridgeCore

/// TouchBridge Native Messaging Host
///
/// Bridges browser extensions (Safari/Chrome) to the TouchBridge daemon
/// via the Unix domain socket. Reads JSON messages from stdin (Chrome NMH protocol:
/// 4-byte length prefix + JSON), writes responses back to stdout.

@main
struct NativeMessagingHost {
    static func main() {
        // Read message from stdin (Chrome NMH protocol)
        guard let message = readNativeMessage() else {
            writeNativeMessage(["result": "failure", "reason": "invalid_input"])
            return
        }

        guard let action = message["action"] as? String else {
            writeNativeMessage(["result": "failure", "reason": "missing_action"])
            return
        }

        switch action {
        case "authenticate":
            let surface = message["surface"] as? String ?? "browser_autofill"
            let result = authenticateViaDaemon(service: surface)
            writeNativeMessage(result)

        case "status":
            let status = checkDaemonStatus()
            writeNativeMessage(status)

        default:
            writeNativeMessage(["result": "failure", "reason": "unknown_action"])
        }
    }

    // MARK: - NMH Protocol

    /// Read a message using Chrome's Native Messaging protocol (4-byte length + JSON).
    static func readNativeMessage() -> [String: Any]? {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        guard fread(&lengthBytes, 1, 4, stdin) == 4 else { return nil }

        let length = UInt32(lengthBytes[0])
            | (UInt32(lengthBytes[1]) << 8)
            | (UInt32(lengthBytes[2]) << 16)
            | (UInt32(lengthBytes[3]) << 24)

        guard length > 0, length < 1_000_000 else { return nil }

        var messageBytes = [UInt8](repeating: 0, count: Int(length))
        guard fread(&messageBytes, 1, Int(length), stdin) == Int(length) else { return nil }

        let data = Data(messageBytes)
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Write a message using Chrome's Native Messaging protocol.
    static func writeNativeMessage(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }

        var length = UInt32(data.count)
        withUnsafeBytes(of: &length) { ptr in
            fwrite(ptr.baseAddress!, 1, 4, stdout)
        }
        data.withUnsafeBytes { ptr in
            fwrite(ptr.baseAddress!, 1, data.count, stdout)
        }
        fflush(stdout)
    }

    // MARK: - Daemon Communication

    static func authenticateViaDaemon(service: String) -> [String: Any] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let socketPath = "\(home)/Library/Application Support/TouchBridge/daemon.sock"

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return ["result": "failure", "reason": "socket_error"]
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(strlen(cstr)) + 1) { dest in
                    strcpy(dest, cstr)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            return ["result": "failure", "reason": "daemon_unavailable"]
        }

        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let user = NSUserName()
        let request = "{\"action\":\"authenticate\",\"user\":\"\(user)\",\"service\":\"\(service)\",\"pid\":\(getpid())}\n"
        let requestData = request.data(using: .utf8)!
        _ = requestData.withUnsafeBytes { ptr in
            send(fd, ptr.baseAddress!, ptr.count, 0)
        }

        var buffer = [UInt8](repeating: 0, count: 1024)
        let received = recv(fd, &buffer, buffer.count - 1, 0)
        guard received > 0 else {
            return ["result": "failure", "reason": "timeout"]
        }

        buffer[received] = 0
        let response = String(cString: buffer)
        if response.contains("\"result\":\"success\"") {
            return ["result": "success"]
        }
        return ["result": "failure", "reason": "denied"]
    }

    static func checkDaemonStatus() -> [String: Any] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let socketPath = "\(home)/Library/Application Support/TouchBridge/daemon.sock"
        let exists = FileManager.default.fileExists(atPath: socketPath)
        return ["connected": exists]
    }
}
