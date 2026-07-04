import Testing
import Foundation
import Security
import CryptoKit
@testable import TouchBridgeCore
@testable import TouchBridgeProtocol

/// Full end-to-end test simulating the entire PAM → Socket → Challenge → Crypto pipeline.
///
/// This test simulates:
/// 1. PAM module connects to daemon socket
/// 2. Daemon issues challenge to companion (mocked)
/// 3. Companion signs nonce with Secure Enclave key (software key in test)
/// 4. Daemon verifies signature
/// 5. PAM module receives success
///
/// All without real BLE — just the crypto and socket layers.

/// Auth handler that simulates the full DaemonCoordinator flow
/// with a mock companion device.
final class FullFlowAuthHandler: PAMAuthHandler, @unchecked Sendable {
    let challengeManager = ChallengeManager()
    let keychainStore: KeychainStore
    let auditLog: AuditLog

    // Simulated companion device
    let companionPrivateKey: SecKey
    let companionPublicKey: SecKey
    let deviceID: String

    init(keychainService: String) {
        self.keychainStore = KeychainStore(service: keychainService)
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-e2e-\(UUID().uuidString)")
        self.auditLog = AuditLog(logDirectory: logDir)

        // Generate companion key pair (simulating Secure Enclave)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        self.companionPrivateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error)!
        self.companionPublicKey = SecKeyCopyPublicKey(companionPrivateKey)!

        self.deviceID = UUID().uuidString

        // Register the companion as a paired device
        let publicKeyData = SecKeyCopyExternalRepresentation(companionPublicKey, &error)! as Data
        let device = PairedDevice(
            deviceID: deviceID,
            publicKey: publicKeyData,
            displayName: "E2E Test iPhone",
            pairedAt: Date()
        )
        try! keychainStore.storePairedDevice(device)
    }

    func authenticateFromPAM(user: String, service: String, pid: Int, timeout: TimeInterval) async -> (success: Bool, reason: String?) {
        // 1. Issue challenge
        let challenge: Challenge
        do {
            challenge = try await challengeManager.issue(for: deviceID)
        } catch {
            return (false, "challenge_issuance_failed")
        }

        // 2. Simulate companion receiving and signing the nonce
        // (In production, this goes over BLE with ECDH encryption)
        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            companionPrivateKey,
            .ecdsaSignatureMessageX962SHA256,
            challenge.nonce as CFData,
            &signError
        ) as Data? else {
            return (false, "signing_failed")
        }

        // 3. Verify the signature
        do {
            let publicKey = try keychainStore.retrievePublicKey(for: deviceID)
            let result = await challengeManager.verify(
                challengeID: challenge.id,
                signature: signature,
                publicKey: publicKey
            )

            // 4. Log the result
            await auditLog.log(AuditEntry(
                sessionID: challenge.id.uuidString,
                surface: "pam_\(service)",
                requestingProcess: service,
                companionDevice: "E2E Test iPhone",
                deviceID: deviceID,
                result: result == .verified ? "VERIFIED" : "FAILED",
                authType: "biometric",
                latencyMs: 50
            ))

            return (result == .verified, result == .verified ? nil : "verification_failed")
        } catch {
            return (false, "key_retrieval_failed")
        }
    }

    func cleanup() {
        try? keychainStore.removeAll()
    }
}

private func makeShortSocketPath() -> String {
    let short = UUID().uuidString.prefix(8)
    return "/tmp/tb-\(short).sock"
}

private func pamConnect(socketPath: String, user: String, service: String) throws -> String {
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

    var tv = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let request = "{\"action\":\"authenticate\",\"user\":\"\(user)\",\"service\":\"\(service)\",\"pid\":\(getpid())}\n"
    _ = request.data(using: .utf8)!.withUnsafeBytes { ptr in
        send(fd, ptr.baseAddress!, ptr.count, 0)
    }

    var buffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)
    guard bytesRead > 0 else { return "" }
    buffer[bytesRead] = 0
    return String(cString: buffer)
}

/// Auth handler that signs the nonce with a key that is NOT registered in the keychain,
/// so signature verification always returns .invalidSignature.
final class BadSignatureAuthHandler: PAMAuthHandler, @unchecked Sendable {
    let challengeManager = ChallengeManager()
    let keychainStore: KeychainStore
    let auditLog: AuditLog
    let deviceID: String

    // The registered (stored) key — what the keychain knows about
    private let storedPublicKey: Data
    // A different key used to sign — deliberately wrong
    private let wrongPrivateKey: SecKey

    init(keychainService: String) {
        self.keychainStore = KeychainStore(service: keychainService)
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-e2e-bad-\(UUID().uuidString)")
        self.auditLog = AuditLog(logDirectory: logDir)
        self.deviceID = UUID().uuidString

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var cfErr: Unmanaged<CFError>?

        // Key that goes in the keychain
        let storedPrivate = SecKeyCreateRandomKey(attrs as CFDictionary, &cfErr)!
        let storedPublic = SecKeyCopyPublicKey(storedPrivate)!
        self.storedPublicKey = SecKeyCopyExternalRepresentation(storedPublic, &cfErr)! as Data

        // Different key used for signing — NOT in keychain
        self.wrongPrivateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &cfErr)!

        let device = PairedDevice(
            deviceID: deviceID,
            publicKey: storedPublicKey,
            displayName: "Bad Sig iPhone",
            pairedAt: Date()
        )
        try! keychainStore.storePairedDevice(device)
    }

    func authenticateFromPAM(user: String, service: String, pid: Int, timeout: TimeInterval) async -> (success: Bool, reason: String?) {
        let challenge: Challenge
        do {
            challenge = try await challengeManager.issue(for: deviceID)
        } catch {
            return (false, "challenge_issuance_failed")
        }

        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            wrongPrivateKey,  // wrong key — verify will fail
            .ecdsaSignatureMessageX962SHA256,
            challenge.nonce as CFData,
            &signError
        ) as Data? else {
            return (false, "signing_failed")
        }

        do {
            let publicKey = try keychainStore.retrievePublicKey(for: deviceID)
            let result = await challengeManager.verify(
                challengeID: challenge.id,
                signature: signature,
                publicKey: publicKey
            )
            await auditLog.log(AuditEntry(
                sessionID: challenge.id.uuidString,
                surface: "pam_\(service)",
                requestingProcess: service,
                companionDevice: "Bad Sig iPhone",
                deviceID: deviceID,
                result: result == .verified ? "VERIFIED" : "FAILED",
                authType: "biometric",
                latencyMs: 50
            ))
            return (result == .verified, result == .verified ? nil : "verification_failed")
        } catch {
            return (false, "key_retrieval_failed")
        }
    }

    func cleanup() {
        try? keychainStore.removeAll()
    }
}

// MARK: - Tests

@Test func fullEndToEndSudoFlow() async throws {
    let socketPath = makeShortSocketPath()
    defer { unlink(socketPath) }

    let keychainService = "dev.touchbridge.test.e2e.\(UUID().uuidString)"
    let handler = FullFlowAuthHandler(keychainService: keychainService)
    defer { handler.cleanup() }

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    // Simulate PAM module calling sudo
    let response = try pamConnect(socketPath: socketPath, user: "arun", service: "sudo")

    #expect(response.contains("\"result\":\"success\""))

    // Verify audit log was written
    let entries = try await handler.auditLog.readEntries()
    #expect(entries.count == 1)
    #expect(entries[0].surface == "pam_sudo")
    #expect(entries[0].result == "VERIFIED")
    #expect(entries[0].companionDevice == "E2E Test iPhone")
}

@Test func fullEndToEndScreensaverFlow() async throws {
    let socketPath = makeShortSocketPath()
    defer { unlink(socketPath) }

    let keychainService = "dev.touchbridge.test.e2e.\(UUID().uuidString)"
    let handler = FullFlowAuthHandler(keychainService: keychainService)
    defer { handler.cleanup() }

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    let response = try pamConnect(socketPath: socketPath, user: "arun", service: "screensaver")

    #expect(response.contains("\"result\":\"success\""))

    let entries = try await handler.auditLog.readEntries()
    #expect(entries[0].surface == "pam_screensaver")
}

@Test func fullEndToEndMultipleSudoCalls() async throws {
    let socketPath = makeShortSocketPath()
    defer { unlink(socketPath) }

    let keychainService = "dev.touchbridge.test.e2e.\(UUID().uuidString)"
    let handler = FullFlowAuthHandler(keychainService: keychainService)
    defer { handler.cleanup() }

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    // Multiple sudo calls should all succeed (no replay issues)
    for i in 0..<3 {
        let response = try pamConnect(socketPath: socketPath, user: "user\(i)", service: "sudo")
        #expect(response.contains("\"result\":\"success\""))
    }

    let entries = try await handler.auditLog.readEntries()
    #expect(entries.count == 3)
    #expect(entries.allSatisfy { $0.result == "VERIFIED" })
}

@Test func fullEndToEndVerifiesNonceNotInLogs() async throws {
    let socketPath = makeShortSocketPath()
    defer { unlink(socketPath) }

    let keychainService = "dev.touchbridge.test.e2e.\(UUID().uuidString)"
    let handler = FullFlowAuthHandler(keychainService: keychainService)
    defer { handler.cleanup() }

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    _ = try pamConnect(socketPath: socketPath, user: "arun", service: "sudo")

    // Read raw log file and verify no nonce field
    let logURL = await handler.auditLog.logFileURL()
    let content = try String(contentsOf: logURL, encoding: .utf8)
    #expect(!content.contains("\"nonce\""))
    #expect(content.contains("\"session_id\""))
    #expect(content.contains("\"VERIFIED\""))
}

@Test func fullEndToEndFailsWithBadSignature() async throws {
    let socketPath = makeShortSocketPath()
    defer { unlink(socketPath) }

    let keychainService = "dev.touchbridge.test.e2e.\(UUID().uuidString)"
    let handler = BadSignatureAuthHandler(keychainService: keychainService)
    defer { handler.cleanup() }

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    let response = try pamConnect(socketPath: socketPath, user: "arun", service: "sudo")

    #expect(response.contains("\"result\":\"failure\""))

    let entries = try await handler.auditLog.readEntries()
    #expect(entries.count == 1)
    #expect(entries[0].result == "FAILED")
}

@Test func fullEndToEndConcurrentRequests() async throws {
    let socketPath = makeShortSocketPath()
    defer { unlink(socketPath) }

    let keychainService = "dev.touchbridge.test.e2e.\(UUID().uuidString)"
    let handler = FullFlowAuthHandler(keychainService: keychainService)
    defer { handler.cleanup() }

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    // Fire 3 PAM connections concurrently
    let results = try await withThrowingTaskGroup(of: String.self) { group in
        for i in 0..<3 {
            group.addTask {
                try pamConnect(socketPath: socketPath, user: "user\(i)", service: "sudo")
            }
        }
        var all: [String] = []
        for try await r in group { all.append(r) }
        return all
    }

    for r in results {
        #expect(r.contains("\"result\":\"success\""))
    }

    let entries = try await handler.auditLog.readEntries()
    #expect(entries.count == 3)
    #expect(entries.allSatisfy { $0.result == "VERIFIED" })
}

@Test func fullEndToEndAuditEntryFields() async throws {
    let socketPath = makeShortSocketPath()
    defer { unlink(socketPath) }

    let keychainService = "dev.touchbridge.test.e2e.\(UUID().uuidString)"
    let handler = FullFlowAuthHandler(keychainService: keychainService)
    defer { handler.cleanup() }

    let server = SocketServer(authHandler: handler, socketPath: socketPath)
    try server.start()
    defer { server.stop() }

    try await Task.sleep(nanoseconds: 100_000_000)

    _ = try pamConnect(socketPath: socketPath, user: "arun", service: "sudo")

    let entries = try await handler.auditLog.readEntries()
    #expect(entries.count == 1)
    let e = entries[0]
    #expect(UUID(uuidString: e.sessionID) != nil)
    #expect(e.requestingProcess == "sudo")
    #expect(e.surface == "pam_sudo")
    #expect(e.result == "VERIFIED")
    #expect(e.authType == "biometric")
    #expect((e.latencyMs ?? 0) > 0)
    #expect(e.companionDevice == "E2E Test iPhone")
}
