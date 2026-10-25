import Testing
import Foundation
@testable import TouchBridgeCore

private final class LockRecorder: @unchecked Sendable {
    private let mutex = NSLock()
    private var calls = 0
    private var results = 0
    private var failures = 0

    func recordLock() { mutex.withLock { calls += 1 } }
    func recordResult(_ result: Result<Void, Error>) {
        mutex.withLock {
            results += 1
            if case .failure = result { failures += 1 }
        }
    }
    var lockCount: Int { mutex.withLock { calls } }
    var resultCount: Int { mutex.withLock { results } }
    var failureCount: Int { mutex.withLock { failures } }
}

@Test func proximityDisabledNeverLocks() async {
    let recorder = LockRecorder()
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 0.03, lockAction: recorder.recordLock)
    monitor.verifiedCompanionCountChanged(1)
    monitor.verifiedCompanionCountChanged(0)
    try? await Task.sleep(nanoseconds: 120_000_000)
    #expect(recorder.lockCount == 0)
}

@Test func proximityInitialAbsenceNeverLocks() async {
    let recorder = LockRecorder()
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 0.03, lockAction: recorder.recordLock)
    monitor.enable()
    monitor.verifiedCompanionCountChanged(0)
    try? await Task.sleep(nanoseconds: 120_000_000)
    #expect(recorder.lockCount == 0)
}

@Test func proximityLocksAfterLastVerifiedCompanionLeaves() async {
    let recorder = LockRecorder()
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 0.03, lockAction: recorder.recordLock)
    monitor.onLockResult = recorder.recordResult
    monitor.enable()
    monitor.verifiedCompanionCountChanged(2)
    monitor.verifiedCompanionCountChanged(1)
    try? await Task.sleep(nanoseconds: 120_000_000)
    #expect(recorder.lockCount == 0)
    monitor.verifiedCompanionCountChanged(0)
    monitor.verifiedCompanionCountChanged(0)
    try? await Task.sleep(nanoseconds: 120_000_000)
    #expect(recorder.lockCount == 1)
    #expect(recorder.resultCount == 1)
}

@Test func proximityVerifiedReconnectCancelsOldCountdown() async {
    let recorder = LockRecorder()
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 0.03, lockAction: recorder.recordLock)
    monitor.enable()
    monitor.verifiedCompanionCountChanged(1)
    monitor.verifiedCompanionCountChanged(0)
    monitor.verifiedCompanionCountChanged(1)
    try? await Task.sleep(nanoseconds: 120_000_000)
    #expect(recorder.lockCount == 0)
    monitor.verifiedCompanionCountChanged(0)
    try? await Task.sleep(nanoseconds: 120_000_000)
    #expect(recorder.lockCount == 1)
}

@Test func proximityDisableCancelsPendingLock() async {
    let recorder = LockRecorder()
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 0.03, lockAction: recorder.recordLock)
    monitor.enable()
    monitor.verifiedCompanionCountChanged(1)
    monitor.verifiedCompanionCountChanged(0)
    monitor.disable()
    monitor.enable()
    try? await Task.sleep(nanoseconds: 120_000_000)
    #expect(recorder.lockCount == 0)
}

@Test func proximityLockFailureIsReported() async {
    enum TestFailure: Error { case unavailable }
    let recorder = LockRecorder()
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 0.03) {
        recorder.recordLock()
        throw TestFailure.unavailable
    }
    monitor.onLockResult = recorder.recordResult
    monitor.enable()
    monitor.verifiedCompanionCountChanged(1)
    monitor.verifiedCompanionCountChanged(0)
    try? await Task.sleep(nanoseconds: 120_000_000)
    #expect(recorder.lockCount == 1)
    #expect(recorder.resultCount == 1)
    #expect(recorder.failureCount == 1)
}

@Test func proximityRSSIDoesNotAuthorizeOrCancelCountdown() async {
    let recorder = LockRecorder()
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 0.03, lockAction: recorder.recordLock)
    monitor.enable()
    monitor.verifiedCompanionCountChanged(1)
    monitor.verifiedCompanionCountChanged(0)
    monitor.rssiUpdated(-30)
    try? await Task.sleep(nanoseconds: 120_000_000)
    #expect(recorder.lockCount == 1)
}
