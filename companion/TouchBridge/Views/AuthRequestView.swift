import SwiftUI

/// Full-screen auth request displayed when a challenge arrives from the Mac.
struct AuthRequestView: View {
    let reason: String
    let macName: String
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var isAuthenticating = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                Image(systemName: "touchid")
                    .font(.system(size: 72))
                    .foregroundColor(.accentColor)
                    .scaleEffect(pulse ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }

                Text("Authentication Request")
                    .font(.title2.bold())
            }
            .padding(.top, 48)
            .padding(.bottom, 32)

            // Request details
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "desktopcomputer")
                        .foregroundColor(.accentColor)
                    Text(macName)
                        .font(.headline)
                    Spacer()
                }

                Divider()

                HStack {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.body)
                    Spacer()
                }
            }
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 24)

            Spacer()

            // Actions
            VStack(spacing: 12) {
                if isAuthenticating {
                    ProgressView("Authenticating...")
                        .padding()
                } else {
                    Button {
                        isAuthenticating = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onApprove()
                    } label: {
                        Label("Approve with Face ID", systemImage: "faceid")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        onDeny()
                    } label: {
                        Text("Deny")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }
}
