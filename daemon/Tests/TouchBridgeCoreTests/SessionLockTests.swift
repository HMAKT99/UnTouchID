import Foundation
import Testing
@testable import TouchBridgeCore

@Test func sessionLockPrefersCGSessionAndRequiresReadback() throws {
    var commands: [(String, [String])] = []
    var probes = 0
    try SessionLockController.lock(
        run: { commands.append(($0, $1)) },
        exists: { $0 == SessionLockController.cgSessionPath },
        probe: { probes += 1; return probes > 1 },
        pause: {},
        verificationAttempts: 2
    )
    #expect(commands.count == 1)
    #expect(commands.first?.0 == SessionLockController.cgSessionPath)
    #expect(commands.first?.1 == ["-suspend"])
    #expect(probes == 2)
}

@Test func sessionLockUsesSupportedKeyboardShortcutWhenCGSessionMissing() throws {
    var commands: [(String, [String])] = []
    var probes = 0
    try SessionLockController.lock(
        run: { commands.append(($0, $1)) },
        exists: { $0 == "/usr/bin/osascript" },
        probe: { probes += 1; return probes > 1 },
        pause: {}
    )
    #expect(commands.first?.0 == "/usr/bin/osascript")
    #expect(commands.first?.1 == ["-e", "tell application \"System Events\" to key code 12 using {control down, command down}"])
}

@Test func sessionLockCommandSuccessWithoutReadbackFails() {
    #expect(throws: SessionLockError.notConfirmed) {
        try SessionLockController.lock(run: { _, _ in }, exists: { _ in true }, probe: { false }, pause: {}, verificationAttempts: 2)
    }
}

@Test func sessionLockUnknownReadbackNeverClaimsSuccess() {
    var commandCalled = false
    #expect(throws: SessionLockError.stateUnavailable) {
        try SessionLockController.lock(run: { _, _ in commandCalled = true }, exists: { _ in true }, probe: { nil }, pause: {})
    }
    #expect(commandCalled)
}

@Test func sessionLockCommandFailureIsPropagated() {
    #expect(throws: SessionLockError.commandFailed(7)) {
        try SessionLockController.lock(run: { _, _ in throw SessionLockError.commandFailed(7) }, exists: { _ in true }, probe: { false }, pause: {})
    }
}

@Test func sessionLockMissingMechanismFails() {
    #expect(throws: SessionLockError.mechanismUnavailable) {
        try SessionLockController.lock(run: { _, _ in Issue.record("Must not execute") }, exists: { _ in false }, probe: { false }, pause: {})
    }
}

@Test func sessionLockInitialMissingPropertyCanBecomeConfirmedAfterLock() throws {
    var probes = 0
    var commandCalled = false
    try SessionLockController.lock(
        run: { _, _ in commandCalled = true },
        exists: { _ in true },
        probe: { probes += 1; return probes > 2 ? true : nil },
        pause: {},
        verificationAttempts: 3
    )
    #expect(commandCalled)
    #expect(probes == 3)
}
