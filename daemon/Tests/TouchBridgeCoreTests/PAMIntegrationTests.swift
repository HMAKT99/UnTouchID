import Testing
import Foundation
import Security
@testable import TouchBridgeCore
@testable import TouchBridgeProtocol

/// Simulates the C PAM module's behavior: connect to Unix socket,
/// send JSON request, parse JSON response.
private func simulatePAMAuth(
    socketPath: String,
    user: String = "testuser",
    service: String = "sudo",
    timeout: Int = 5
) throws -> (success: Bool, reason: String?) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketServerError.socketCreationFailed(errno) }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            for i in 0..<pathBytes.count { dest[i] = pathBytes[i] }
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { throw SocketServerError.bindFailed(errno) }

    var tv = timeval(tv_sec: __darwin_time_t(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // Build JSON request (mirrors pam_touchbridge.c behavior)
    let request = "{\"action\":\"authenticate\",\"user\":\"\(user)\",\"service\":\"\(service)\",\"pid\":\(getpid())}\n"
    let requestData = request.data(using: .utf8)!
    _ = requestData.withUnsafeBytes { ptr in
        send(fd, ptr.baseAddress!, ptr.count, 0)
    }

    // Read response
    var buffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)
    guard bytesRead > 0 else { return (false, "timeout") }

    buffer[bytesRead] = 0
    let responseStr = String(cString: buffer)

    // Parse like the C module does: simple string search
    let success = responseStr.contains("\"result\":\"success\"")

    // Extract reason if present
    var reason: String?
    if let range = responseStr.range(of: "\"reason\":\"") {
        let afterReason = responseStr[range.upperBound...]
        if let endRange = afterReason.range(of: "\"") {
            reason = String(afterReason[..<endRange.lowerBound])
        }
    }

    return (success, reason)
}

private func makeShortSocketPath() -> String {
    let short = UUID().uuidString.prefix(8)
    return "/tmp/tb-\(short).sock"
}

// MARK: - Tests

@Test func pamAuthWithNoCompanionReturnsFailed() async throws {
    let socketPath = makeShortSocketPath()
    defer { unlink(socketPath) }

    // Mock handler simulating no companion connected
    let handler = MockPAMAuthHandler()
    handler.shouldSucceed = false
    handler.failureReason = "no_companion_connected"

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    let (success, reason) = try simulatePAMAuth(socketPath: socketPath)
    #expect(!success)
    #expect(reason == "no_companion_connected")
}

@Test func pamAuthSuccessReturnsSuccess() async throws {
    let socketPath = makeShortSocketPath()
    defer { unlink(socketPath) }

    let handler = MockPAMAuthHandler()
    handler.shouldSucceed = true

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    let (success, _) = try simulatePAMAuth(socketPath: socketPath, service: "sudo")
    #expect(success)
    #expect(handler.lastRequest?.service == "sudo")
}

@Test func pamAuthPassesCorrectUserAndService() async throws {
    let socketPath = makeShortSocketPath()
    defer { unlink(socketPath) }

    let handler = MockPAMAuthHandler()
    handler.shouldSucceed = true

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    _ = try simulatePAMAuth(socketPath: socketPath, user: "arun", service: "screensaver")

    #expect(handler.lastRequest?.user == "arun")
    #expect(handler.lastRequest?.service == "screensaver")
}

@Test func pamAuthConnectionRefusedWhenNoDaemon() throws {
    // Try connecting to a non-existent socket — should fail gracefully
    let socketPath = "/tmp/tb-nonexistent-\(UUID().uuidString.prefix(8)).sock"
    let result = try? simulatePAMAuth(socketPath: socketPath)

    // Either throws or returns failure
    if let result {
        #expect(!result.success)
    }
    // If it throws, that's also correct behavior (PAM module returns PAM_AUTH_ERR)
}

@Test func pamAuthMultipleSequentialRequests() async throws {
    let socketPath = makeShortSocketPath()
    defer { unlink(socketPath) }

    let handler = MockPAMAuthHandler()
    handler.shouldSucceed = true

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    // Simulate multiple sudo calls in sequence
    for i in 0..<5 {
        let (success, _) = try simulatePAMAuth(
            socketPath: socketPath,
            user: "user\(i)",
            service: "sudo"
        )
        #expect(success)
    }
}
