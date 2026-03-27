import Foundation
import OSLog

/// JSON request from the PAM module.
public struct PAMRequest: Codable, Sendable {
    public let action: String
    public let user: String
    public let service: String
    public let pid: Int

    public init(action: String, user: String, service: String, pid: Int) {
        self.action = action
        self.user = user
        self.service = service
        self.pid = pid
    }
}

/// JSON response to the PAM module.
public struct PAMResponse: Codable, Sendable {
    public let result: String
    public let reason: String?

    public init(result: String, reason: String? = nil) {
        self.result = result
        self.reason = reason
    }

    public static let success = PAMResponse(result: "success")

    public static func failure(_ reason: String) -> PAMResponse {
        PAMResponse(result: "failure", reason: reason)
    }
}

/// Protocol for handling PAM authentication requests — enables testing without DaemonCoordinator.
public protocol PAMAuthHandler: AnyObject, Sendable {
    func authenticateFromPAM(user: String, service: String, pid: Int, timeout: TimeInterval) async -> (success: Bool, reason: String?)
}

/// Unix domain socket server for PAM module communication.
///
/// Listens on `~/Library/Application Support/TouchBridge/daemon.sock`.
/// Each PAM connection sends a JSON request line, receives a JSON response line.
public final class SocketServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "SocketServer")

    private let socketPath: String
    private let authHandler: PAMAuthHandler
    private let policyEngine: PolicyEngine

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.touchbridge.socket", qos: .userInitiated)

    /// Whether the socket server is currently listening.
    public private(set) var isListening: Bool = false

    public init(
        authHandler: PAMAuthHandler,
        policyEngine: PolicyEngine = PolicyEngine(),
        socketPath: String? = nil
    ) {
        self.authHandler = authHandler
        self.policyEngine = policyEngine

        if let path = socketPath {
            self.socketPath = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.socketPath = "\(home)/Library/Application Support/TouchBridge/daemon.sock"
        }
    }

    /// Start listening on the Unix domain socket.
    public func start() throws {
        // Ensure directory exists
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Remove stale socket
        unlink(socketPath)

        // Create socket
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw SocketServerError.socketCreationFailed(errno)
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(serverFD)
            serverFD = -1
            throw SocketServerError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(serverFD)
            serverFD = -1
            throw SocketServerError.bindFailed(err)
        }

        // Set socket permissions to owner-only
        chmod(socketPath, 0o600)

        // Listen
        guard listen(serverFD, 5) == 0 else {
            let err = errno
            close(serverFD)
            serverFD = -1
            throw SocketServerError.listenFailed(err)
        }

        // Accept connections via GCD
        let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverFD, fd >= 0 {
                close(fd)
                self?.serverFD = -1
            }
        }
        acceptSource = source
        source.resume()

        isListening = true
        logger.info("Socket server listening on \(self.socketPath)")
    }

    /// Stop the socket server.
    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
        isListening = false
        logger.info("Socket server stopped")
    }

    /// The path of the Unix domain socket.
    public var path: String { socketPath }

    // MARK: - Private

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverFD, sockPtr, &addrLen)
            }
        }

        guard clientFD >= 0 else {
            logger.warning("Accept failed: \(errno)")
            return
        }

        // Handle each connection on a separate task
        Task {
            await handleConnection(fd: clientFD)
        }
    }

    private func handleConnection(fd: Int32) async {
        defer { close(fd) }

        // Read request (max 4KB, single line)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)

        guard bytesRead > 0 else {
            logger.warning("Empty read from PAM client")
            return
        }

        buffer[bytesRead] = 0
        let requestString = String(cString: buffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let requestData = requestString.data(using: .utf8) else {
            sendResponse(fd: fd, response: .failure("invalid_request"))
            return
        }

        // Parse request
        let request: PAMRequest
        do {
            request = try JSONDecoder().decode(PAMRequest.self, from: requestData)
        } catch {
            logger.warning("Failed to parse PAM request: \(error.localizedDescription)")
            sendResponse(fd: fd, response: .failure("parse_error"))
            return
        }

        guard request.action == "authenticate" else {
            sendResponse(fd: fd, response: .failure("unknown_action"))
            return
        }

        logger.info("PAM auth request: user=\(request.user) service=\(request.service) pid=\(request.pid)")

        // Dispatch to auth handler with timeout from policy
        let timeout = policyEngine.authTimeout()
        let (success, reason) = await authHandler.authenticateFromPAM(
            user: request.user,
            service: request.service,
            pid: request.pid,
            timeout: timeout
        )

        let response = success ? PAMResponse.success : PAMResponse.failure(reason ?? "authentication_failed")
        sendResponse(fd: fd, response: response)

        logger.info("PAM auth result: user=\(request.user) service=\(request.service) result=\(response.result)")
    }

    private func sendResponse(fd: Int32, response: PAMResponse) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(response)
            data.append(contentsOf: "\n".utf8)
            data.withUnsafeBytes { ptr in
                _ = send(fd, ptr.baseAddress!, ptr.count, 0)
            }
        } catch {
            logger.error("Failed to encode PAM response: \(error.localizedDescription)")
        }
    }
}

public enum SocketServerError: Error, Sendable {
    case socketCreationFailed(Int32)
    case pathTooLong
    case bindFailed(Int32)
    case listenFailed(Int32)
}
