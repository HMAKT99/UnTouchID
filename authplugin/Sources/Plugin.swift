import Foundation
import Security
import OSLog

/// TouchBridge Authorization Plugin
///
/// Intercepts `system.privilege.admin` and related authorization rights,
/// replacing the SecurityAgent biometric sheet with a "Check your iPhone"
/// flow that routes through the TouchBridge daemon.
///
/// This handles:
/// - App Store purchases
/// - Software installation (.pkg)
/// - System Settings privacy changes
///
/// The plugin communicates with the daemon via the same Unix domain socket
/// used by the PAM module.

private let logger = Logger(subsystem: "dev.touchbridge", category: "AuthPlugin")

// MARK: - Authorization Plugin Entry Points

/// Plugin state stored across callbacks.
class TouchBridgeAuthState {
    var socketPath: String
    var timeout: TimeInterval = 15.0
    var lastResult: Bool = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.socketPath = "\(home)/Library/Application Support/TouchBridge/daemon.sock"
    }
}

private var pluginState: TouchBridgeAuthState?

/// Called when the plugin is created.
public func AuthorizationPluginCreate(
    _ callbacks: UnsafePointer<AuthorizationCallbacks>,
    _ outPlugin: UnsafeMutablePointer<AuthorizationPluginRef?>,
    _ pluginInterface: UnsafePointer<AuthorizationPluginInterface>
) -> OSStatus {
    logger.info("TouchBridge auth plugin created")
    pluginState = TouchBridgeAuthState()
    return errAuthorizationSuccess
}

/// Called when the plugin is destroyed.
public func AuthorizationPluginDestroy(_ plugin: AuthorizationPluginRef) -> OSStatus {
    logger.info("TouchBridge auth plugin destroyed")
    pluginState = nil
    return errAuthorizationSuccess
}

// MARK: - Mechanism Entry Points

/// Called when the mechanism is created for an authorization right.
public func MechanismCreate(
    _ plugin: AuthorizationPluginRef,
    _ engine: AuthorizationEngineRef,
    _ mechanismId: UnsafePointer<CChar>,
    _ outMechanism: UnsafeMutablePointer<AuthorizationMechanismRef?>
) -> OSStatus {
    let id = String(cString: mechanismId)
    logger.info("Mechanism created: \(id)")
    return errAuthorizationSuccess
}

/// Called when the mechanism is invoked (auth decision needed).
public func MechanismInvoke(_ mechanism: AuthorizationMechanismRef) -> OSStatus {
    logger.info("TouchBridge auth mechanism invoked")

    guard let state = pluginState else {
        logger.error("Plugin state not initialized")
        return errAuthorizationDenied
    }

    // Connect to daemon socket and request authentication
    let result = authenticateViaDaemon(socketPath: state.socketPath, timeout: state.timeout)

    if result {
        logger.info("Authorization granted via TouchBridge")
        state.lastResult = true
        return errAuthorizationSuccess
    } else {
        logger.info("Authorization denied — falling through to standard auth")
        state.lastResult = false
        return errAuthorizationDenied
    }
}

/// Called when the mechanism is deactivated.
public func MechanismDeactivate(_ mechanism: AuthorizationMechanismRef) -> OSStatus {
    logger.info("Mechanism deactivated")
    return errAuthorizationSuccess
}

/// Called when the mechanism is destroyed.
public func MechanismDestroy(_ mechanism: AuthorizationMechanismRef) -> OSStatus {
    logger.info("Mechanism destroyed")
    return errAuthorizationSuccess
}

// MARK: - Daemon Communication

/// Authenticate via the TouchBridge daemon's Unix domain socket.
/// Same protocol as the PAM module.
private func authenticateViaDaemon(socketPath: String, timeout: TimeInterval) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        logger.error("Failed to create socket")
        return false
    }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)

    guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        logger.error("Socket path too long")
        return false
    }

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

    guard connectResult == 0 else {
        logger.warning("Cannot connect to daemon socket — daemon may not be running")
        return false
    }

    // Set timeout
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // Send auth request
    let user = NSUserName()
    let request = "{\"action\":\"authenticate\",\"user\":\"\(user)\",\"service\":\"authplugin_system\",\"pid\":\(getpid())}\n"

    guard let requestData = request.data(using: .utf8) else { return false }
    let sent = requestData.withUnsafeBytes { ptr in
        send(fd, ptr.baseAddress!, ptr.count, 0)
    }
    guard sent == requestData.count else { return false }

    // Read response
    var buffer = [UInt8](repeating: 0, count: 1024)
    let received = recv(fd, &buffer, buffer.count - 1, 0)
    guard received > 0 else {
        logger.warning("Timeout or error reading daemon response")
        return false
    }

    buffer[received] = 0
    let response = String(cString: buffer)
    return response.contains("\"result\":\"success\"")
}
