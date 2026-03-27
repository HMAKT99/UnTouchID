import Testing
import Foundation
@testable import TouchBridgeCore

private func makeTempPlistDir() -> (dir: URL, path: String) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-policy-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("policy.plist").path
    return (dir, path)
}

private func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Timeout & RSSI Tests

@Test func defaultAuthTimeout() {
    let engine = PolicyEngine(plistPath: "/nonexistent/path/policy.plist")
    #expect(engine.authTimeout() == 15.0)
}

@Test func defaultRSSIThreshold() {
    let engine = PolicyEngine(plistPath: "/nonexistent/path/policy.plist")
    #expect(engine.rssiThreshold() == -75)
}

@Test func customAuthTimeoutFromPlist() throws {
    let (dir, path) = makeTempPlistDir()
    defer { cleanup(dir) }

    let dict: NSDictionary = ["AuthTimeoutSeconds": 30.0, "RSSIThreshold": -60]
    dict.write(toFile: path, atomically: true)

    let engine = PolicyEngine(plistPath: path)
    #expect(engine.authTimeout() == 30.0)
    #expect(engine.rssiThreshold() == -60)
}

@Test func invalidAuthTimeoutUsesDefault() throws {
    let (dir, path) = makeTempPlistDir()
    defer { cleanup(dir) }

    let dict: NSDictionary = ["AuthTimeoutSeconds": -5.0]
    dict.write(toFile: path, atomically: true)

    let engine = PolicyEngine(plistPath: path)
    #expect(engine.authTimeout() == 15.0)
}

// MARK: - Surface Policy Tests

@Test func defaultSudoPolicyRequiresBiometric() {
    let engine = PolicyEngine(plistPath: "/nonexistent")
    let pol = engine.policy(for: "sudo")
    #expect(pol.mode == .biometricRequired)
}

@Test func defaultScreensaverPolicyIsProximitySession() {
    let engine = PolicyEngine(plistPath: "/nonexistent")
    let pol = engine.policy(for: "screensaver")
    #expect(pol.mode == .proximitySession)
    #expect(pol.sessionTTLSeconds == 1800)
}

@Test func defaultBrowserAutofillPolicyIsProximitySession() {
    let engine = PolicyEngine(plistPath: "/nonexistent")
    let pol = engine.policy(for: "browser_autofill")
    #expect(pol.mode == .proximitySession)
    #expect(pol.sessionTTLSeconds == 600)
}

@Test func unknownSurfaceDefaultsToBiometric() {
    let engine = PolicyEngine(plistPath: "/nonexistent")
    let pol = engine.policy(for: "unknown_surface")
    #expect(pol.mode == .biometricRequired)
}

@Test func customSurfacePolicyFromPlist() throws {
    let (dir, path) = makeTempPlistDir()
    defer { cleanup(dir) }

    let dict: NSDictionary = [
        "Surfaces": [
            "sudo": ["mode": "proximity_session", "sessionTTLSeconds": 300.0]
        ]
    ]
    dict.write(toFile: path, atomically: true)

    let engine = PolicyEngine(plistPath: path)
    let pol = engine.policy(for: "sudo")
    #expect(pol.mode == .proximitySession)
    #expect(pol.sessionTTLSeconds == 300)
}

// MARK: - Proximity Session Tests

@Test func requiresBiometricForSudo() {
    let engine = PolicyEngine(plistPath: "/nonexistent")
    #expect(engine.requiresBiometric(for: "sudo", deviceID: "device1"))
}

@Test func proximitySessionSkipsBiometricAfterAuth() {
    let engine = PolicyEngine(plistPath: "/nonexistent")
    let deviceID = "device-test"

    // First auth for screensaver requires biometric
    #expect(engine.requiresBiometric(for: "screensaver", deviceID: deviceID))

    // Record auth — creates proximity session
    engine.recordAuthentication(surface: "screensaver", deviceID: deviceID)

    // Second auth should NOT require biometric (session active)
    #expect(!engine.requiresBiometric(for: "screensaver", deviceID: deviceID))
}

@Test func proximitySessionDoesNotApplyToDifferentSurface() {
    let engine = PolicyEngine(plistPath: "/nonexistent")
    let deviceID = "device-test"

    engine.recordAuthentication(surface: "screensaver", deviceID: deviceID)

    // sudo always requires biometric regardless
    #expect(engine.requiresBiometric(for: "sudo", deviceID: deviceID))
}

@Test func invalidateAllSessionsClearsProximity() {
    let engine = PolicyEngine(plistPath: "/nonexistent")
    let deviceID = "device-test"

    engine.recordAuthentication(surface: "screensaver", deviceID: deviceID)
    #expect(!engine.requiresBiometric(for: "screensaver", deviceID: deviceID))

    engine.invalidateAllSessions()
    #expect(engine.requiresBiometric(for: "screensaver", deviceID: deviceID))
}

@Test func allPoliciesReturnsDefaultsAndOverrides() throws {
    let (dir, path) = makeTempPlistDir()
    defer { cleanup(dir) }

    let dict: NSDictionary = [
        "Surfaces": [
            "custom_surface": ["mode": "biometric_required"]
        ]
    ]
    dict.write(toFile: path, atomically: true)

    let engine = PolicyEngine(plistPath: path)
    let all = engine.allPolicies()

    #expect(all["sudo"]?.mode == .biometricRequired)
    #expect(all["screensaver"]?.mode == .proximitySession)
    #expect(all["custom_surface"]?.mode == .biometricRequired)
}
