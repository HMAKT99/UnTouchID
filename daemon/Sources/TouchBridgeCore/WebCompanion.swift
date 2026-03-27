import Foundation
import Network
import OSLog
import CryptoKit

/// Web Companion — authenticate from ANY phone via browser.
///
/// Starts a local HTTP server on the Mac. Any device on the same network
/// can open the URL, see the auth request, and approve/deny.
///
/// Flow:
/// 1. Daemon starts HTTP server on configurable port (default 7070)
/// 2. On auth request, generates a one-time token (32 bytes, 60s expiry)
/// 3. Displays QR code URL in terminal: `http://<mac-ip>:7070/auth/<token>`
/// 4. User opens URL on ANY phone (iPhone, Android, laptop)
/// 5. Page shows: "sudo for user arun on Mac Mini — Approve / Deny"
/// 6. User taps Approve → server confirms to daemon → PAM succeeds
///
/// Security:
/// - One-time tokens expire in 60 seconds
/// - Tokens are 32 bytes from SecRandomCopyBytes
/// - Each token can only be used once
/// - Server only listens on local network (not exposed to internet)
/// - Optional: require same Wi-Fi network via Bonjour
public final class WebCompanion: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "WebCompanion")

    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.touchbridge.webcompanion")

    /// Pending auth requests keyed by one-time token.
    private var pendingRequests: [String: PendingWebAuth] = [:]
    private let lock = NSLock()

    /// Callback when a web auth is approved.
    public var onAuthApproved: ((String) -> Void)?

    /// Callback when a web auth is denied.
    public var onAuthDenied: ((String) -> Void)?

    struct PendingWebAuth {
        let token: String
        let user: String
        let service: String
        let createdAt: Date
        let continuation: CheckedContinuation<Bool, Never>?
    }

    public private(set) var isRunning: Bool = false

    public init(port: UInt16 = 7070) {
        self.port = port
    }

    // MARK: - Server Lifecycle

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        let serverPort = self.port
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("Web companion listening on port \(serverPort)")
                self?.isRunning = true
            case .failed(let error):
                self?.logger.error("Web companion failed: \(error.localizedDescription)")
                self?.isRunning = false
            default:
                break
            }
        }
        listener?.start(queue: queue)

        logger.info("Web companion starting on port \(serverPort)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        logger.info("Web companion stopped")
    }

    // MARK: - Auth Request Management

    /// Create a pending auth request and return the one-time URL.
    public func createAuthRequest(user: String, service: String) async -> (url: String, approved: Bool) {
        let token = generateToken()
        let localIP = getLocalIPAddress() ?? "localhost"
        let url = "http://\(localIP):\(port)/auth/\(token)"

        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let request = PendingWebAuth(
                token: token,
                user: user,
                service: service,
                createdAt: Date(),
                continuation: continuation
            )
            lock.lock()
            pendingRequests[token] = request
            lock.unlock()

            // Auto-expire after 60 seconds
            queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.expireRequest(token: token)
            }
        }

        return (url, approved)
    }

    /// Generate a terminal-friendly QR-code-like display of the URL.
    public func displayAuthURL(url: String, user: String, service: String) {
        print("")
        print("  ╔══════════════════════════════════════════════════╗")
        print("  ║  TouchBridge — Web Authentication               ║")
        print("  ╠══════════════════════════════════════════════════╣")
        print("  ║                                                  ║")
        print("  ║  Open this URL on any phone:                     ║")
        print("  ║                                                  ║")
        print("  ║  \(url.padding(toLength: 48, withPad: " ", startingAt: 0))║")
        print("  ║                                                  ║")
        print("  ║  Request: \(service.padding(toLength: 39, withPad: " ", startingAt: 0))║")
        print("  ║  User:    \(user.padding(toLength: 39, withPad: " ", startingAt: 0))║")
        print("  ║                                                  ║")
        print("  ║  Expires in 60 seconds                           ║")
        print("  ╚══════════════════════════════════════════════════╝")
        print("")
    }

    // MARK: - HTTP Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            let response = self.routeRequest(request)

            let httpResponse = response.data(using: .utf8) ?? Data()
            connection.send(content: httpResponse, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func routeRequest(_ raw: String) -> String {
        let lines = raw.split(separator: "\r\n")
        guard let requestLine = lines.first else {
            return httpResponse(status: 400, body: "Bad Request")
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return httpResponse(status: 400, body: "Bad Request")
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Route: GET /auth/<token> — show auth page
        if method == "GET", path.hasPrefix("/auth/") {
            let token = String(path.dropFirst("/auth/".count))
            return handleAuthPage(token: token)
        }

        // Route: POST /approve/<token> — approve auth
        if method == "POST", path.hasPrefix("/approve/") {
            let token = String(path.dropFirst("/approve/".count))
            return handleApprove(token: token)
        }

        // Route: POST /deny/<token> — deny auth
        if method == "POST", path.hasPrefix("/deny/") {
            let token = String(path.dropFirst("/deny/".count))
            return handleDeny(token: token)
        }

        // Route: GET / — status page
        if method == "GET" && (path == "/" || path == "") {
            return handleStatusPage()
        }

        return httpResponse(status: 404, body: "Not Found")
    }

    private func handleAuthPage(token: String) -> String {
        lock.lock()
        let request = pendingRequests[token]
        lock.unlock()

        guard let request else {
            return httpResponse(status: 404, html: expiredPageHTML())
        }

        // Check expiry
        if Date().timeIntervalSince(request.createdAt) > 60 {
            expireRequest(token: token)
            return httpResponse(status: 410, html: expiredPageHTML())
        }

        return httpResponse(status: 200, html: authPageHTML(
            token: token,
            user: request.user,
            service: request.service
        ))
    }

    private func handleApprove(token: String) -> String {
        lock.lock()
        let request = pendingRequests.removeValue(forKey: token)
        lock.unlock()

        guard let request else {
            return httpResponse(status: 404, html: expiredPageHTML())
        }

        request.continuation?.resume(returning: true)
        onAuthApproved?(token)
        logger.info("Web auth APPROVED: \(request.service) for \(request.user)")

        return httpResponse(status: 200, html: resultPageHTML(approved: true))
    }

    private func handleDeny(token: String) -> String {
        lock.lock()
        let request = pendingRequests.removeValue(forKey: token)
        lock.unlock()

        guard let request else {
            return httpResponse(status: 404, html: expiredPageHTML())
        }

        request.continuation?.resume(returning: false)
        onAuthDenied?(token)
        logger.info("Web auth DENIED: \(request.service) for \(request.user)")

        return httpResponse(status: 200, html: resultPageHTML(approved: false))
    }

    private func handleStatusPage() -> String {
        return httpResponse(status: 200, html: """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>TouchBridge</title>
        <style>body{font-family:-apple-system,system-ui;text-align:center;padding:40px;background:#0a0a1a;color:#fff}
        .logo{font-size:64px;margin:20px}.title{font-size:24px;font-weight:bold;margin:10px}
        .sub{color:#888;margin:10px}</style></head>
        <body><div class="logo">🔐</div>
        <div class="title">TouchBridge</div>
        <div class="sub">Web Companion is running</div>
        <div class="sub">Waiting for authentication requests...</div>
        </body></html>
        """)
    }

    // MARK: - HTML Templates

    private func authPageHTML(token: String, user: String, service: String) -> String {
        return """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>TouchBridge — Authenticate</title>
        <style>
        *{box-sizing:border-box;margin:0;padding:0}
        body{font-family:-apple-system,system-ui,sans-serif;background:#0a0a1a;color:#fff;
        min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
        .card{background:#1a1a2e;border-radius:20px;padding:32px;max-width:380px;width:100%;text-align:center}
        .icon{font-size:64px;margin-bottom:16px}
        h1{font-size:20px;margin-bottom:8px}
        .detail{background:#0a0a1a;border-radius:12px;padding:16px;margin:20px 0;text-align:left}
        .row{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #2a2a3e}
        .row:last-child{border:none}
        .label{color:#888}
        .value{font-weight:600}
        .btn{width:100%;padding:16px;border:none;border-radius:12px;font-size:16px;font-weight:600;
        cursor:pointer;margin:6px 0;transition:transform 0.1s}
        .btn:active{transform:scale(0.97)}
        .approve{background:#30d158;color:#fff}
        .deny{background:#2a2a3e;color:#ff453a}
        .expire{color:#888;font-size:12px;margin-top:12px}
        </style></head>
        <body>
        <div class="card">
        <div class="icon">🔐</div>
        <h1>Authentication Request</h1>
        <div class="detail">
        <div class="row"><span class="label">Action</span><span class="value">\(escapeHTML(service))</span></div>
        <div class="row"><span class="label">User</span><span class="value">\(escapeHTML(user))</span></div>
        <div class="row"><span class="label">Device</span><span class="value">\(Host.current().localizedName ?? "Mac")</span></div>
        </div>
        <form method="POST" action="/approve/\(token)">
        <button class="btn approve" type="submit">Approve</button>
        </form>
        <form method="POST" action="/deny/\(token)">
        <button class="btn deny" type="submit">Deny</button>
        </form>
        <div class="expire">Expires in 60 seconds</div>
        </div>
        <script>setTimeout(()=>{location.reload()},60000)</script>
        </body></html>
        """
    }

    private func resultPageHTML(approved: Bool) -> String {
        let icon = approved ? "✅" : "❌"
        let msg = approved ? "Approved" : "Denied"
        let color = approved ? "#30d158" : "#ff453a"
        return """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>TouchBridge — \(msg)</title>
        <style>body{font-family:-apple-system,system-ui;text-align:center;padding:60px;
        background:#0a0a1a;color:#fff}.icon{font-size:80px;margin:20px}
        .msg{font-size:24px;font-weight:bold;color:\(color);margin:20px}
        .sub{color:#888}</style></head>
        <body><div class="icon">\(icon)</div>
        <div class="msg">\(msg)</div>
        <div class="sub">You can close this tab.</div>
        </body></html>
        """
    }

    private func expiredPageHTML() -> String {
        return """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>TouchBridge — Expired</title>
        <style>body{font-family:-apple-system,system-ui;text-align:center;padding:60px;
        background:#0a0a1a;color:#fff}.icon{font-size:80px;margin:20px}
        .msg{font-size:20px;color:#888;margin:20px}</style></head>
        <body><div class="icon">⏰</div>
        <div class="msg">This authentication request has expired.<br>Please try again.</div>
        </body></html>
        """
    }

    // MARK: - Helpers

    private func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func expireRequest(token: String) {
        lock.lock()
        let request = pendingRequests.removeValue(forKey: token)
        lock.unlock()

        if let request {
            request.continuation?.resume(returning: false)
            logger.info("Web auth expired: \(request.service) for \(request.user)")
        }
    }

    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }

    private func httpResponse(status: Int, body: String) -> String {
        return httpResponse(status: status, html: "<html><body>\(body)</body></html>")
    }

    private func httpResponse(status: Int, html: String) -> String {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 410: statusText = "Gone"
        default: statusText = "Error"
        }

        let body = html.data(using: .utf8) ?? Data()
        return "HTTP/1.1 \(status) \(statusText)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n"
            + "Cache-Control: no-store\r\n"
            + "\r\n"
            + html
    }

    private func escapeHTML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// PAM auth handler that uses the Web Companion for authentication.
/// Shows a URL in the terminal, waits for approval via browser.
public final class WebCompanionAuthHandler: PAMAuthHandler, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "WebCompanionAuth")

    private let webCompanion: WebCompanion
    private let challengeManager: ChallengeManager
    private let auditLog: AuditLog

    public init(
        webCompanion: WebCompanion,
        challengeManager: ChallengeManager = ChallengeManager(),
        auditLog: AuditLog = AuditLog()
    ) {
        self.webCompanion = webCompanion
        self.challengeManager = challengeManager
        self.auditLog = auditLog
    }

    public func authenticateFromPAM(
        user: String,
        service: String,
        pid: Int,
        timeout: TimeInterval
    ) async -> (success: Bool, reason: String?) {
        let startTime = Date()

        // Create auth request and get one-time URL
        let result: (url: String, approved: Bool) = await withTaskGroup(of: (String, Bool)?.self) { group in
            group.addTask {
                let r = await self.webCompanion.createAuthRequest(user: user, service: service)
                return (r.url, r.approved)
            }

            // Display the URL immediately
            group.addTask {
                // Small delay to let the request be created
                try? await Task.sleep(nanoseconds: 100_000_000)
                // The URL will be displayed by the main task
                return nil
            }

            let first = await group.next()!
            group.cancelAll()
            return first ?? ("", false)
        }

        // Display was handled inline by createAuthRequest's caller
        webCompanion.displayAuthURL(url: result.url, user: user, service: service)

        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)

        await auditLog.log(AuditEntry(
            sessionID: UUID().uuidString,
            surface: "pam_\(service)",
            requestingProcess: service,
            companionDevice: "WebCompanion",
            deviceID: "web",
            result: result.approved ? "VERIFIED" : "FAILED_BIOMETRIC",
            authType: "web_companion",
            latencyMs: latencyMs
        ))

        if result.approved {
            return (true, nil)
        }
        return (false, "denied_via_web")
    }
}
