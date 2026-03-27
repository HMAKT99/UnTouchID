import SwiftUI
import WatchKit

/// Full-screen auth request on Apple Watch.
///
/// Shows the requesting service and Mac name.
/// User taps Approve or Deny.
struct AuthRequestWatchView: View {
    let challenge: WatchConnectivityManager.WatchChallenge
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Icon
                Image(systemName: "touchid")
                    .font(.system(size: 36))
                    .foregroundColor(.blue)

                // Title
                Text("Auth Request")
                    .font(.headline)

                // Details
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "desktopcomputer")
                            .font(.caption2)
                        Text(challenge.macName)
                            .font(.caption)
                    }

                    HStack {
                        Image(systemName: "lock.shield")
                            .font(.caption2)
                        Text(challenge.reason)
                            .font(.caption)
                    }

                    if !challenge.user.isEmpty {
                        HStack {
                            Image(systemName: "person")
                                .font(.caption2)
                            Text(challenge.user)
                                .font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

                // Approve button
                Button(action: onApprove) {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                // Deny button
                Button(action: onDeny) {
                    Label("Deny", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal, 4)
        }
    }
}
