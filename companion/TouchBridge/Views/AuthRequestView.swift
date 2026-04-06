import SwiftUI

/// Full-screen auth request displayed when a challenge arrives from the Mac.
/// Styled to match the native macOS passkey "Sign In" dialog.
struct AuthRequestView: View {
    let reason: String
    let macName: String
    /// Observed from AppState — when true, replace the biometric prompt with a key-invalidated error.
    let keyInvalidated: Bool
    /// Observed from AppState — when true, show a denial message instead of dismissing silently.
    let wasDenied: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var isAuthenticating = false

    var body: some View {
        VStack(spacing: 0) {
            // Header — mirrors macOS passkey dialog header row
            HStack {
                Label("Sign In", systemImage: "person.badge.key.fill")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel") {
                    onDeny()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            Spacer()

            // App icon — rounded square, matches Passwords app style
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)

                Image(systemName: "touchid")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
            }
            .padding(.bottom, 20)

            if wasDenied {
                // Denied state
                deniedBody
            } else if keyInvalidated {
                // Key invalidated state
                keyInvalidatedBody
            } else {
                // Normal authentication state
                normalBody
            }

            Spacer()
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Normal state

    @ViewBuilder
    private var normalBody: some View {
        Text("Use Face ID to authenticate?")
            .font(.title3.bold())
            .multilineTextAlignment(.center)
            .padding(.bottom, 12)

        Text("You will be authenticated on \"\(macName)\" for \"\(reason)\".")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)

        // Biometric graphic — pink tint matches macOS passkey dialog
        VStack(spacing: 8) {
            Image(systemName: "touchid")
                .font(.system(size: 80))
                .foregroundStyle(.pink)

            Text("Continue with Face ID")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 40)

        // Primary action button
        VStack(spacing: 0) {
            if isAuthenticating {
                ProgressView("Authenticating...")
                    .padding()
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    isAuthenticating = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onApprove()
                } label: {
                    Text("Continue with Face ID")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAuthenticating)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Key invalidated state

    @ViewBuilder
    private var keyInvalidatedBody: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 48))
            .foregroundStyle(.yellow)
            .padding(.bottom, 12)

        Text("Signing key invalid")
            .font(.title3.bold())
            .padding(.bottom, 8)

        Text("Your Face ID / Touch ID enrollment changed since pairing.\n\nOpen Settings → Unpair → Re-pair to restore authentication.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)

        Button("Dismiss") {
            onDeny()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: - Denied state

    @ViewBuilder
    private var deniedBody: some View {
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: 48))
            .foregroundStyle(.red)
            .padding(.bottom, 12)

        Text("Request denied")
            .font(.title3.bold())
            .padding(.bottom, 8)

        Text("Your Mac will fall back to password authentication.\nRun sudo again on your Mac if you want to retry.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)

        Button("Close") {
            onDeny()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}
