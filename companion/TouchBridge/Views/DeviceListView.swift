import SwiftUI

struct DeviceListView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        List {
            if let macName = UserDefaults.standard.string(forKey: "pairedMacName") {
                Section("Paired Mac") {
                    HStack {
                        Image(systemName: "desktopcomputer")
                        VStack(alignment: .leading) {
                            Text(macName)
                                .font(.headline)
                            Text(appState.isConnected ? "Connected" : "Disconnected")
                                .font(.caption)
                                .foregroundStyle(appState.isConnected ? .green : .secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Devices")
    }
}
