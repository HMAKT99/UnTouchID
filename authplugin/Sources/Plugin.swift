import Foundation
import Security
import OSLog

private let logger = Logger(subsystem: "dev.touchbridge", category: "AuthPlugin")

/// This optional plugin has no root-pinned v2 verifier. Deny creation before
/// publishing any mechanism interface; never trust a user-daemon success value.
/// Opaque pointers preserve the native AuthorizationPluginCreate C ABI without
/// importing callback structs that contain unsupported Swift function pointers.
@_cdecl("AuthorizationPluginCreate")
public func AuthorizationPluginCreate(
    _ callbacks: UnsafeRawPointer?,
    _ outPlugin: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ outPluginInterface: UnsafeMutablePointer<UnsafeRawPointer?>?
) -> OSStatus {
    _ = callbacks
    outPlugin?.pointee = nil
    outPluginInterface?.pointee = nil
    logger.error("Authorization plugin unavailable: privileged v2 evidence verification is not implemented")
    return errAuthorizationDenied
}
