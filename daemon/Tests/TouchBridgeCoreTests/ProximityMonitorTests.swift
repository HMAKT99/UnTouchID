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
    // Use a generous delay (0.5s) and cancel at 200ms — 2.5x margin before the deadline fires.
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 0.5)
    var lockCalled = false
    monitor.onShouldLock = { lockCalled = true }
    monitor.enable()
    monitor.connectionStateChanged(connected: false)
    try? await Task.sleep(nanoseconds: 200_000_000)   // 200ms — well before 500ms deadline
    monitor.connectionStateChanged(connected: true)   // reconnect cancels the timer
    try? await Task.sleep(nanoseconds: 600_000_000)  // 600ms — original deadline is long past
    #expect(!lockCalled)
}

@Test func proximityLockCancelledOnDisable() async {
    let monitor = ProximityMonitor(rssiThreshold: -80, disconnectDelay: 0.5)
    var lockCalled = false
    monitor.onShouldLock = { lockCalled = true }
    monitor.enable()
    monitor.connectionStateChanged(connected: false)
    try? await Task.sleep(nanoseconds: 200_000_000)   // 200ms — well before 500ms deadline
    monitor.disable()
    try? await Task.sleep(nanoseconds: 600_000_000)
    #expect(!lockCalled)
}
