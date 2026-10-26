import Foundation

func expect(_ value: @autoclosure () -> Bool, line: UInt = #line) {
    precondition(value(), "Protected installation regression failed at test line " + String(line))
}
let checked = NSMutableArray()
let uninstall = try ProtectedInstallation.command(for: .uninstall, validate: {
    checked.add($0); return true
})
expect(uninstall == "/bin/bash /Library/Security/TouchBridge/uninstall.sh")
expect(!uninstall.contains("/usr/local"))
expect(checked.contains("/Library/Security/TouchBridge/pam-common.sh"))
let activation = try ProtectedInstallation.command(for: .activate, validate: { _ in true })
expect(activation == "/bin/bash /Library/Security/TouchBridge/patch-pam.sh")
do {
    _ = try ProtectedInstallation.command(for: .uninstall, validate: { _ in false })
    preconditionFailure("Unsafe helper must not produce an administrator command")
} catch {}
expect(ProtectedInstallation.isProtectedFile("/bin/bash"))
expect(!ProtectedInstallation.isProtectedFile("/private/tmp/missing-touchbridge-helper"))
expect(!ProtectedInstallation.isProtectedFile("relative/path"))
expect(!ProtectedInstallation.isProtectedFile("/Library/../bin/bash"))
let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let helper = temp.appendingPathComponent("uninstall.sh")
try Data("exit 0\n".utf8).write(to: helper)
expect(!ProtectedInstallation.isProtectedFile(helper.path))
let link = temp.appendingPathComponent("link")
try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/bash")
expect(!ProtectedInstallation.isProtectedFile(link.path))
print("PASS: only protected v2 helper commands; unsafe/missing/symlink paths rejected")
