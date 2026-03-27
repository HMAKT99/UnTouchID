import SwiftUI
import WatchConnectivity

@main
struct TouchBridgeWatchApp: App {
    @StateObject private var connectivityManager = WatchConnectivityManager()

    var body: some Scene {
        WindowGroup {
            ContentView(manager: connectivityManager)
        }
    }
}

struct ContentView: View {
    @ObservedObject var manager: WatchConnectivityManager

    var body: some View {
        if let pending = manager.pendingChallenge {
            AuthRequestWatchView(
                challenge: pending,
                onApprove: { manager.approve() },
                onDeny: { manager.deny() }
            )
        } else {
            StatusWatchView(manager: manager)
        }
    }
}
