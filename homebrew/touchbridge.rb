cask "touchbridge" do
  version "1.1.2"
  sha256 "da7af193723ad1d5ffd4739033c440916e9175183dc82e70899c0bcbbbf4b1e9"

  url "https://github.com/HMAKT99/UnTouchID/releases/download/v#{version}/TouchBridge-#{version}.pkg"
  name "TouchBridge"
  desc "Use your phone's Face ID or fingerprint to authenticate on any Mac"
  homepage "https://github.com/HMAKT99/UnTouchID"

  depends_on macos: :ventura

  pkg "TouchBridge-#{version}.pkg"

  # IMPORTANT: remove the pam_touchbridge hook BEFORE deleting the module.
  # Deleting the .so while /etc/pam.d still references it makes sudo unable to
  # initialize PAM — a full sudo lockout. Handle all three hook locations:
  # /etc/pam.d/sudo_local (Sonoma+, unprotected), and legacy direct edits of
  # /etc/pam.d/sudo and /etc/pam.d/screensaver (restore backup or strip line).
  # Only then remove binaries.
  uninstall script: {
              executable: "/bin/bash",
              args:       ["-c", "for f in /etc/pam.d/sudo /etc/pam.d/screensaver; do b=\"$f.touchbridge-backup\"; if [ -f \"$b\" ]; then cp \"$b\" \"$f\"; rm -f \"$b\"; elif grep -q pam_touchbridge \"$f\" 2>/dev/null; then t=$(mktemp); grep -v pam_touchbridge \"$f\" > \"$t\"; cat \"$t\" > \"$f\"; rm -f \"$t\"; fi; done; sl=/etc/pam.d/sudo_local; if [ -f \"$sl\" ] && grep -q pam_touchbridge \"$sl\"; then t=$(mktemp); grep -v pam_touchbridge \"$sl\" > \"$t\" || true; if grep -qE '[^[:space:]]' \"$t\"; then cat \"$t\" > \"$sl\"; else rm -f \"$sl\"; fi; rm -f \"$t\"; fi; launchctl bootout gui/$(id -u)/dev.touchbridge.daemon 2>/dev/null; rm -f /usr/local/bin/touchbridged /usr/local/bin/touchbridge-test /usr/local/bin/touchbridge-nmh /usr/local/lib/pam/pam_touchbridge.so ~/Library/LaunchAgents/dev.touchbridge.daemon.plist"],
              sudo:       true,
            }

  zap trash: [
    "~/Library/Application Support/TouchBridge",
    "~/Library/Logs/TouchBridge",
  ]

  caveats <<~EOS
    TouchBridge has been installed.

    Activate the sudo hook (shows a diff and asks before changing anything):
      sudo bash /usr/local/share/touchbridge/patch-pam.sh

    Note: upgrading via brew deactivates the sudo hook — re-run the command
    above after each upgrade to reactivate it.

    To get started:
      touchbridged serve --simulator    # test without phone
      sudo echo 'It works!'            # try it

    For phone auth:
      touchbridged serve --web          # any phone, no app install

    More info: https://github.com/HMAKT99/UnTouchID
  EOS
end
