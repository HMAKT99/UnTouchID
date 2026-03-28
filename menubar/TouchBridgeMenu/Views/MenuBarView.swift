import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "touchid")
                    .font(.title2)
                    .foregroundStyle(state.isConnected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TouchBridge")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Connection status
            if let device = state.pairedDeviceName {
                HStack {
                    Circle()
                        .fill(state.isConnected ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Text(device)
                        .font(.subheadline)
                    Spacer()
                    Text(state.isConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
            }

            // Recent auth events
            if !state.recentEvents.isEmpty {
                Text("Recent Activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ForEach(state.recentEvents.prefix(5)) { event in
                    HStack {
                        Image(systemName: event.result == "VERIFIED" ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(event.result == "VERIFIED" ? .green : .red)
                            .font(.caption)
                        Text(event.surface)
                            .font(.caption)
                        Spacer()
                        Text(formatTime(event.ts))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }

                Divider()
                    .padding(.top, 4)
            }

            // Actions
            if !state.isInstalled {
                Button {
                    // Open setup wizard
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Set Up TouchBridge...", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Settings...", systemImage: "gear")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit TouchBridge")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    private var statusText: String {
        if !state.isInstalled { return "Not installed" }
        if !state.isDaemonRunning { return "Daemon not running" }
        if state.isConnected { return "Ready — phone connected" }
        return "Waiting for phone..."
    }

    private func formatTime(_ iso: String) -> String {
        let parts = iso.split(separator: "T")
        if parts.count == 2 {
            let time = parts[1].prefix(5)
            return String(time)
        }
        return iso
    }
}
