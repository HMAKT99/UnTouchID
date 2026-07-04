import Testing
import Foundation
@testable import TouchBridgeCore

@Test func proximityLockNotTriggeredWhenDisabled() async {
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 0.05)
    var lockCalled = false
    monitor.onShouldLock = { lockCalled = true }
    // NOT calling monitor.enable()
    monitor.connectionStateChanged(connected: false)
    try? await Task.sleep(nanoseconds: 150_000_000)
    #expect(!lockCalled)
}

@Test func proximityLockTriggeredAfterDisconnectDelay() async {
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 0.05)
    var lockCalled = false
    monitor.onShouldLock = { lockCalled = true }
    monitor.enable()
    monitor.connectionStateChanged(connected: false)
    try? await Task.sleep(nanoseconds: 150_000_000)
    #expect(lockCalled)
}

@Test func proximityLockCancelledOnReconnect() async {
    // Cancel immediately after disconnect — no sleep in between. Sleeping part of the
    // deadline made this flake on loaded CI runners: Task.sleep only guarantees a
    // MINIMUM duration, so a 200ms sleep could overshoot a 500ms deadline and the
    // lock fired before the cancellation ran. The 2s deadline gives even a stalled
    // runner ample headroom to execute the reconnect first.
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 2.0)
    var lockCalled = false
    monitor.onShouldLock = { lockCalled = true }
    monitor.enable()
    monitor.connectionStateChanged(connected: false)
    monitor.connectionStateChanged(connected: true)   // reconnect cancels the timer
    try? await Task.sleep(nanoseconds: 2_500_000_000) // past the original deadline
    #expect(!lockCalled)
}

@Test func proximityLockCancelledOnDisable() async {
    // Same immediate-cancel pattern as above — see comment there.
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 2.0)
    var lockCalled = false
    monitor.onShouldLock = { lockCalled = true }
    monitor.enable()
    monitor.connectionStateChanged(connected: false)
    monitor.disable()
    try? await Task.sleep(nanoseconds: 2_500_000_000)
    #expect(!lockCalled)
}
