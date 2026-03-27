import Testing
import Foundation
@testable import TouchBridgeCore

@Test func simulatorAutoApproveReturnsSuccess() async {
    let handler = SimulatorAuthHandler(mode: .autoApprove)

    let (success, reason) = await handler.authenticateFromPAM(
        user: "testuser",
        service: "sudo",
        pid: 1234,
        timeout: 15.0
    )

    #expect(success)
    #expect(reason == nil)
}

@Test func simulatorAutoDenyReturnsFailure() async {
    let handler = SimulatorAuthHandler(mode: .autoDeny)

    let (success, reason) = await handler.authenticateFromPAM(
        user: "testuser",
        service: "sudo",
        pid: 1234,
        timeout: 15.0
    )

    #expect(!success)
    #expect(reason == "user_denied")
}

@Test func simulatorAutoApproveRunsFullCryptoPipeline() async {
    let challengeManager = ChallengeManager()
    let logDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-sim-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: logDir) }

    let auditLog = AuditLog(logDirectory: logDir)
    let handler = SimulatorAuthHandler(
        mode: .autoApprove,
        challengeManager: challengeManager,
        auditLog: auditLog
    )

    let (success, _) = await handler.authenticateFromPAM(
        user: "arun",
        service: "sudo",
        pid: 9999,
        timeout: 15.0
    )

    #expect(success)

    // Verify audit log was written
    let entries = try! await auditLog.readEntries()
    #expect(entries.count == 1)
    #expect(entries[0].surface == "pam_sudo")
    #expect(entries[0].result == "VERIFIED")
    #expect(entries[0].authType == "simulated")
    #expect(entries[0].companionDevice == "Simulator")
}

@Test func simulatorMultipleAuthsAllSucceed() async {
    let handler = SimulatorAuthHandler(mode: .autoApprove)

    for i in 0..<5 {
        let (success, _) = await handler.authenticateFromPAM(
            user: "user\(i)",
            service: "sudo",
            pid: 1000 + i,
            timeout: 15.0
        )
        #expect(success)
    }
}

@Test func simulatorWorksWithSocketServer() async throws {
    let socketPath = "/tmp/tb-sim-\(UUID().uuidString.prefix(8)).sock"
    defer { unlink(socketPath) }

    let handler = SimulatorAuthHandler(mode: .autoApprove)
    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    // Simulate PAM module connecting
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
    #expect(connectResult == 0)

    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let request = "{\"action\":\"authenticate\",\"user\":\"arun\",\"service\":\"sudo\",\"pid\":42}\n"
    _ = request.data(using: .utf8)!.withUnsafeBytes { ptr in
        send(fd, ptr.baseAddress!, ptr.count, 0)
    }

    var buffer = [UInt8](repeating: 0, count: 4096)
    let received = recv(fd, &buffer, buffer.count - 1, 0)
    #expect(received > 0)

    buffer[received] = 0
    let response = String(cString: buffer)
    #expect(response.contains("\"result\":\"success\""))
}
