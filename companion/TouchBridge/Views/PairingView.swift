import SwiftUI

/// QR code scanning / manual entry view for pairing with a Mac.
struct PairingView: View {
    @ObservedObject var appState: AppState
    @State private var pairingStatus: PairingStatus = .idle
    @State private var showManualEntry = false
    @State private var showScanner = false
    @State private var manualInput = ""
    @State private var discoveredMacs: [UUID] = []

    enum PairingStatus: Equatable {
        case idle
        case scanning
        case connecting
        case exchangingKeys
        case paired
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Pair with your Mac")
                .font(.title2.bold())

            Text("Run 'touchbridge-test pair' on your Mac, then scan the QR code it shows.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            switch pairingStatus {
            case .idle:
                VStack(spacing: 12) {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showManualEntry = true
                    } label: {
                        Label("Enter Pairing Data", systemImage: "keyboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

            case .scanning:
                ProgressView("Scanning for Mac...")

                if !discoveredMacs.isEmpty {
                    ForEach(discoveredMacs, id: \.self) { mac in
                        Button {
                            connectTo(mac)
                        } label: {
                            Label("Mac (\(mac.uuidString.prefix(8))...)", systemImage: "desktopcomputer")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal)
                    }
                }

            case .connecting:
                ProgressView("Connecting...")

            case .exchangingKeys:
                ProgressView("Exchanging keys...")

            case .paired:
                Label("Paired!", systemImage: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)

            case .failed(let error):
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.body)
                    .foregroundStyle(.red)

                Button("Try Again") {
                    pairingStatus = .idle
                }
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Pairing")
        .sheet(isPresented: $showManualEntry) {
            ManualPairingSheet(
                input: $manualInput,
                onSubmit: { data in
                    showManualEntry = false
                    handlePairingData(data)
                }
            )
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { scanned in
                    showScanner = false
                    handlePairingData(scanned)
                }
                .ignoresSafeArea()
                .navigationTitle("Scan QR Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showScanner = false }
                    }
                }
            }
        }
        .onAppear {
            // Wire coordinator pairing callbacks
            appState.coordinator.onPairingComplete = { [weak appState] macID in
                pairingStatus = .paired
                appState?.isPaired = true
                appState?.statusMessage = "Paired with Mac"
            }
            appState.coordinator.onPairingFailed = {
                pairingStatus = .failed("Mac rejected pairing. Run 'touchbridge-test pair' again and use fresh pairing data — tokens expire after 5 minutes.")
            }
        }
    }

    private func startScanning() {
        pairingStatus = .scanning
        appState.coordinator.startScanning()

        // Poll for discovered devices
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            discoveredMacs = appState.coordinator.discoveredMacs
            if pairingStatus != .scanning {
                timer.invalidate()
            }
        }
    }

    private func connectTo(_ peripheralID: UUID) {
        pairingStatus = .connecting
        appState.coordinator.connect(to: peripheralID)

        // After connection, send pairing request
        appState.coordinator.onConnectionChanged = { connected in
            if connected {
                pairingStatus = .exchangingKeys
                appState.coordinator.sendPairingRequest(macName: "Mac")
            }
        }
    }

    private func handlePairingData(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else {
            pairingStatus = .failed("Invalid pairing data")
            return
        }

        do {
            let payload = try JSONDecoder().decode(PairingPayloadCompanion.self, from: data)

            // Scan for the Mac advertised in the payload, holding its one-time token.
            // Pairing is only complete once the Mac validates the token and accepts
            // (onPairingComplete fires) — not when the payload parses.
            pairingStatus = .scanning
            appState.coordinator.beginPairing(
                serviceUUID: payload.serviceUUID,
                token: payload.pairingToken,
                macName: payload.macName
            )

            // Auto-connect to the Mac as soon as it's discovered
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                if pairingStatus == .scanning, let mac = appState.coordinator.discoveredMacs.first {
                    timer.invalidate()
                    connectTo(mac)
                } else if pairingStatus != .scanning {
                    timer.invalidate()
                }
            }
        } catch {
            pairingStatus = .failed("Failed to parse: \(error.localizedDescription)")
        }
    }
}

/// Manual entry sheet for pairing data.
struct ManualPairingSheet: View {
    @Binding var input: String
    var onSubmit: (String) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Paste the pairing JSON from your Mac's terminal:")
                    .font(.body)
                    .foregroundStyle(.secondary)

                TextEditor(text: $input)
                    .font(.caption.monospaced())
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3))
                    )
                    .padding(.horizontal)

                Button("Pair") {
                    onSubmit(input)
                }
                .buttonStyle(.borderedProminent)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("Manual Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Local pairing payload type (mirrors the daemon's PairingPayload).
struct PairingPayloadCompanion: Codable {
    let version: UInt8
    let serviceUUID: String
    let pairingToken: Data
    let macName: String
}
