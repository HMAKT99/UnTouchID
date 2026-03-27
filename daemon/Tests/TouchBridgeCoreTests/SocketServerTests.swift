import Testing
import Foundation
@testable import TouchBridgeCore

/// Mock auth handler that returns configurable results.
final class MockPAMAuthHandler: PAMAuthHandler, @unchecked Sendable {
    var shouldSucceed: Bool = true
    var failureReason: String = "mock_failure"
    var lastRequest: (user: String, service: String, pid: Int)?

    func authenticateFromPAM(user: String, service: String, pid: Int, timeout: TimeInterval) async -> (success: Bool, reason: String?) {
        lastRequest = (user, service, pid)
        if shouldSucceed {
            return (true, nil)
        } else {
            return (false, failureReason)
        }
    }
}

/// Connect to a Unix socket, send a string, and read the response.
private func sendToSocket(path: String, message: String) throws -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketServerError.socketCreationFailed(errno) }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            for i in 0..<pathBytes.count {
                dest[i] = pathBytes[i]
            }
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { throw SocketServerError.bindFailed(errno) }

    // Set timeout
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // Send
    let data = message.data(using: .utf8)!
    _ = data.withUnsafeBytes { ptr in
        send(fd, ptr.baseAddress!, ptr.count, 0)
    }

    // Receive
    var buffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)
    guard bytesRead > 0 else { return "" }

    buffer[bytesRead] = 0
    return String(cString: buffer)
}

private func makeTempSocketPath() -> String {
    // sockaddr_un.sun_path is limited to 104 bytes on macOS — keep path short
    let short = UUID().uuidString.prefix(8)
    return "/tmp/tb-\(short).sock"
}

// MARK: - Tests

@Test func socketServerAcceptsAndRespondsSuccess() async throws {
    let socketPath = makeTempSocketPath()
    defer { unlink(socketPath) }

    let handler = MockPAMAuthHandler()
    handler.shouldSucceed = true

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    #expect(server.isListening)

    // Give server a moment to be ready
    try await Task.sleep(nanoseconds: 100_000_000)

    let request = """
    {"action":"authenticate","user":"testuser","service":"sudo","pid":1234}
    """

    let response = try sendToSocket(path: socketPath, message: request)
    #expect(response.contains("\"result\":\"success\""))

    // Verify handler received the request
    #expect(handler.lastRequest?.user == "testuser")
    #expect(handler.lastRequest?.service == "sudo")
    #expect(handler.lastRequest?.pid == 1234)
}

@Test func socketServerAcceptsAndRespondsFailure() async throws {
    let socketPath = makeTempSocketPath()
    defer { unlink(socketPath) }

    let handler = MockPAMAuthHandler()
    handler.shouldSucceed = false
    handler.failureReason = "no_companion_connected"

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    let request = """
    {"action":"authenticate","user":"arun","service":"screensaver","pid":5678}
    """

    let response = try sendToSocket(path: socketPath, message: request)
    #expect(response.contains("\"result\":\"failure\""))
    #expect(response.contains("no_companion_connected"))
}

@Test func socketServerRejectsInvalidJSON() async throws {
    let socketPath = makeTempSocketPath()
    defer { unlink(socketPath) }

    let handler = MockPAMAuthHandler()
    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    let response = try sendToSocket(path: socketPath, message: "not json at all")
    #expect(response.contains("\"result\":\"failure\""))
    #expect(response.contains("parse_error"))
}

@Test func socketServerRejectsUnknownAction() async throws {
    let socketPath = makeTempSocketPath()
    defer { unlink(socketPath) }

    let handler = MockPAMAuthHandler()
    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    let request = """
    {"action":"delete_everything","user":"test","service":"sudo","pid":1}
    """

    let response = try sendToSocket(path: socketPath, message: request)
    #expect(response.contains("\"result\":\"failure\""))
    #expect(response.contains("unknown_action"))
}

@Test func socketServerHandlesMultipleConnections() async throws {
    let socketPath = makeTempSocketPath()
    defer { unlink(socketPath) }

    let handler = MockPAMAuthHandler()
    handler.shouldSucceed = true

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    // Send multiple requests sequentially
    for i in 0..<3 {
        let request = """
        {"action":"authenticate","user":"user\(i)","service":"sudo","pid":\(1000 + i)}
        """
        let response = try sendToSocket(path: socketPath, message: request)
        #expect(response.contains("\"result\":\"success\""))
    }
}

@Test func socketServerStopRemovesSocket() async throws {
    let socketPath = makeTempSocketPath()

    let handler = MockPAMAuthHandler()
    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()

    #expect(FileManager.default.fileExists(atPath: socketPath))

    server.stop()

    #expect(!FileManager.default.fileExists(atPath: socketPath))
    #expect(!server.isListening)
}

@Test func socketServerIsIdempotentOnRestart() async throws {
    let socketPath = makeTempSocketPath()
    defer { unlink(socketPath) }

    let handler = MockPAMAuthHandler()
    let server = SocketServer(authHandler: handler, socketPath: socketPath)

    // Start, stop, start again — should work without error
    try server.start()
    server.stop()
    // Allow GCD cancel handler to complete
    try await Task.sleep(nanoseconds: 100_000_000)
    try server.start()
    defer { server.stop() }

    #expect(server.isListening)
}
