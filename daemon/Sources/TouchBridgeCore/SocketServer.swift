import Foundation
import OSLog

/// JSON request from the PAM module.
public struct PAMRequest: Codable, Sendable {
    public let action: String
    public let user: String
    public let service: String
    public let pid: Int
    public let evidenceVersion: Int?
    public let challenge: Data?

    public init(action: String, user: String, service: String, pid: Int, evidenceVersion: Int? = nil, challenge: Data? = nil) {
        self.action = action
        self.user = user
        self.service = service
        self.pid = pid
        self.evidenceVersion = evidenceVersion
        self.challenge = challenge
    }
}

/// JSON response to the PAM module.
public struct PAMResponse: Codable, Sendable {
    public let result: String
    public let reason: String?
    public let proof: PAMProof?

    public init(result: String, reason: String? = nil, proof: PAMProof? = nil) {
        self.result = result
        self.reason = reason
        self.proof = proof
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

public struct PAMProof: Codable, Sendable, Equatable {
    public let deviceID: String
    public let signature: Data
    public init(deviceID: String, signature: Data) { self.deviceID = deviceID; self.signature = signature }
}
public protocol PAMProofAuthHandler: AnyObject, Sendable {
    func authenticateProof(challenge: Data, timeout: TimeInterval) async -> PAMProof?
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
    private let queue: DispatchQueue
    private let lifecycleLock = NSLock()

    /// Whether the socket server is currently listening.
    public var isListening: Bool { lifecycleLock.withLock { serverFD >= 0 } }

    public init(
        authHandler: PAMAuthHandler,
        policyEngine: PolicyEngine = PolicyEngine(),
        socketPath: String? = nil,
        eventQueue: DispatchQueue = DispatchQueue(label: "dev.touchbridge.socket", qos: .userInitiated)
    ) {
        self.authHandler = authHandler
        self.policyEngine = policyEngine
        self.queue = eventQueue

        if let path = socketPath {
            self.socketPath = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.socketPath = "\(home)/Library/Application Support/TouchBridge/daemon.sock"
        }
    }

    /// Start listening on the Unix domain socket.
    public func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard serverFD < 0 else { return }
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
        let listenerFD = serverFD
        let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection(listenerFD: listenerFD)
        }
        source.setCancelHandler {
            // The source exclusively owns this descriptor until cancellation
            // completes. A delayed callback must never touch a newer listener.
            close(listenerFD)
        }
        acceptSource = source
        source.resume()

        logger.info("Socket server listening on \(self.socketPath)")
    }

    /// Stop the socket server.
    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard acceptSource != nil else { return }
        acceptSource?.cancel()
        acceptSource = nil
        serverFD = -1
        unlink(socketPath)
        logger.info("Socket server stopped")
    }

    deinit { stop() }

    /// The path of the Unix domain socket.
    public var path: String { socketPath }

    // MARK: - Private

    private func acceptConnection(listenerFD: Int32) {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(listenerFD, sockPtr, &addrLen)
            }
        }

        guard clientFD >= 0 else {
            logger.warning("Accept failed: \(errno)")
            return
        }

        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // Handle each connection on a separate task
        Task {
            await handleConnection(fd: clientFD)
        }
    }

    private func handleConnection(fd: Int32) async {
        defer { close(fd) }

        let (requestData, errorReason) = readFramedRequest(fd: fd)
        guard let data = requestData else {
            sendResponse(fd: fd, response: .failure(errorReason ?? "incomplete_request"))
            return
        }

        // Parse request
        let request: PAMRequest
        do {
            request = try JSONDecoder().decode(PAMRequest.self, from: data)
        } catch {
            logger.warning("Failed to parse PAM request: \(error.localizedDescription)")
            sendResponse(fd: fd, response: .failure("parse_error"))
            return
        }

        guard request.action == "authenticate" || request.action == "diagnostic_authenticate" else {
            sendResponse(fd: fd, response: .failure("unknown_action"))
            return
        }

        logger.info("PAM auth request: user=\(request.user) service=\(request.service) pid=\(request.pid)")
        let timeout = policyEngine.authTimeout()

        if request.action == "authenticate" {
            await handleAuthenticate(fd: fd, request: request, timeout: timeout)
        } else {
            await handleDiagnostic(fd: fd, request: request, timeout: timeout)
        }
    }

    private func readFramedRequest(fd: Int32) -> (data: Data?, errorReason: String?) {
        // Newline framing, bounded reads and a socket deadline reject truncated input.
        var socketTimeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))
        var requestData = Data()
        let readDeadline = Date().addingTimeInterval(3)
        while requestData.count < 4096, Date() < readDeadline {
            var chunk = [UInt8](repeating: 0, count: min(512, 4096 - requestData.count))
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            if let newline = chunk[..<count].firstIndex(of: 10) {
                guard newline == count - 1 else { return (nil, "invalid_frame") }
                requestData.append(contentsOf: chunk[..<newline])
                return (requestData, nil)
            }
            requestData.append(contentsOf: chunk[..<count])
        }
        return (nil, "incomplete_request")
    }

    private func handleAuthenticate(fd: Int32, request: PAMRequest, timeout: TimeInterval) async {
        guard request.evidenceVersion == 2, let challenge = request.challenge,
              let handler = authHandler as? PAMProofAuthHandler else {
            sendResponse(fd: fd, response: .failure("evidence_v2_required"))
            return
        }
        let response: PAMResponse
        if let proof = await handler.authenticateProof(challenge: challenge, timeout: timeout) {
            response = PAMResponse(result: "success", proof: proof)
        } else {
            response = .failure("invalid_or_missing_proof")
        }
        sendResponse(fd: fd, response: response)
        logger.info("PAM auth result: user=\(request.user) service=\(request.service) result=\(response.result)")
    }

    private func handleDiagnostic(fd: Int32, request: PAMRequest, timeout: TimeInterval) async {
        guard request.evidenceVersion == nil, request.challenge == nil else {
            sendResponse(fd: fd, response: .failure("diagnostic_evidence_forbidden"))
            return
        }
        let (success, reason) = await authHandler.authenticateFromPAM(user: request.user, service: request.service, pid: request.pid, timeout: timeout)
        let response = success ? PAMResponse.success : .failure(reason ?? "authentication_failed")
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
                var offset = 0
                while offset < ptr.count {
                    let count = send(fd, ptr.baseAddress!.advanced(by: offset), ptr.count - offset, 0)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }; offset += count
                }
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
