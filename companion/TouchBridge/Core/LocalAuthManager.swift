import Foundation
import LocalAuthentication

/// Errors from local authentication.
public enum LocalAuthError: Error, Sendable {
    case biometricUnavailable
    case authenticationFailed(String)
    case userCancelled
}

/// Wraps `LAContext` for biometric authentication prompts.
///
/// Important: `LAContext.evaluatePolicy` must be called on the main thread.
/// This manager handles the main-thread dispatch internally.
public final class LocalAuthManager: @unchecked Sendable {
    public init() {}

    /// Prompt the user for biometric authentication.
    ///
    /// - Parameter reason: The reason string shown on the biometric prompt
    ///   (e.g., "sudo on Arun's Mac Mini").
    /// - Returns: `true` if authentication succeeded.
    /// - Throws: `LocalAuthError` on failure or cancellation.
    @MainActor
    public func authenticateUser(reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Deny"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw LocalAuthError.biometricUnavailable
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return success
        } catch let authError as LAError {
            switch authError.code {
            case .userCancel, .appCancel, .systemCancel:
                throw LocalAuthError.userCancelled
            default:
                throw LocalAuthError.authenticationFailed(authError.localizedDescription)
            }
        }
    }

    /// Check if biometric authentication is available on this device.
    public func isBiometricAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Returns the type of biometric available (Face ID, Touch ID, or none).
    public func biometricType() -> LABiometryType {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return context.biometryType
    }
}
