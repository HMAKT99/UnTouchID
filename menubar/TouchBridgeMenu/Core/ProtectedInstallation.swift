import Darwin
import Foundation

/// Privileged UI actions must never execute helpers under user-writable paths.
enum ProtectedInstallation {
    static let base = "/Library/Security/TouchBridge"
    static let module = base + "/pam_touchbridge.so"
    enum Action { case activate, uninstall }
    enum Failure: LocalizedError {
        case unsafeInstallation
        var errorDescription: String? {
            "Install the reviewed v2 package and enroll verified keys before using this action. The protected installation is missing or unsafe."
        }
    }

    static func command(for action: Action, validate: (String) -> Bool = isProtectedFile) throws -> String {
        let script = base + (action == .activate ? "/patch-pam.sh" : "/uninstall.sh")
        guard [module, base + "/touchbridge-trust", base + "/pam-common.sh", script].allSatisfy(validate) else {
            throw Failure.unsafeInstallation
        }
        return "/bin/bash " + script
    }

    static var isInstalled: Bool {
        isProtectedFile(module) && isProtectedFile(base + "/touchbridge-trust")
    }

    /// Check every descriptor, including all ancestors, before requesting root.
    /// The conservative ACL policy matches the native PAM verifier.
    static func isProtectedFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/"), !parts.isEmpty,
              !parts.contains(".."), !parts.contains(".") else { return false }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard trusted(fd, directory: true) else { return false }
        for (index, part) in parts.enumerated() {
            let directory = index < parts.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0)
            let next = openat(fd, String(part), flags)
            guard next >= 0 else { return false }
            close(fd)
            fd = next
            guard trusted(fd, directory: directory) else { return false }
        }
        return true
    }

    private static func trusted(_ fd: Int32, directory: Bool) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else { return false }
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?
        // Darwin returns zero when an entry exists, unlike POSIX's one.
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0
    }
}
