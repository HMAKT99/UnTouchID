import SwiftUI

/// Default Watch view showing connection status.
struct StatusWatchView: View {
    @ObservedObject var manager: WatchConnectivityManager

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "touchid")
                    .font(.system(size: 32))
                    .foregroundColor(manager.isReachable ? .green : .gray)

                Text("TouchBridge")
                    .font(.headline)

                // Connection status
                HStack(spacing: 4) {
                    Circle()
                        .fill(manager.isReachable ? .green : .orange)
                        .frame(width: 6, height: 6)

                    Text(manager.isReachable ? "Connected" : "Waiting...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Stats
                if manager.challengeCount > 0 {
                    Divider()

                    VStack(spacing: 4) {
                        HStack {
                            Text("Authenticated")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(manager.challengeCount)")
                                .font(.caption.bold())
                        }

                        if let last = manager.lastResult {
                            HStack {
                                Text("Last")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(last)
                                    .font(.caption.bold())
                                    .foregroundColor(last == "Approved" ? .green : .red)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
