cask "touchbridge" do
  version "2.0.1"
  sha256 "87c8fde3f87febe0da79c0a6afddd7f82817c148ff3d7c8be1a57c3dcd7bf667"

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
  # /etc/pam.d/sudo and /etc/pam.d/screensaver (strip only our auth entries).
  # Only then remove binaries.
  uninstall script: {
              executable: "/bin/bash",
              args:       ["/Library/Security/TouchBridge/uninstall.sh"],
              sudo:       true,
            }

  zap trash: [
    "~/Library/Application Support/TouchBridge",
    "~/Library/Logs/TouchBridge",
  ]

  caveats <<~EOS
    TouchBridge has been installed.

    Activate the sudo hook (shows a diff and asks before changing anything):
      sudo bash /Library/Security/TouchBridge/patch-pam.sh

    Note: upgrading via brew deactivates the sudo hook — re-run the command
    above after each upgrade to reactivate it.

    First pair the native phone app, verify Mac/phone fingerprints, and explicitly
    enroll them with /Library/Security/TouchBridge/touchbridge-trust as root.
    Simulator and web modes cannot authorize privileged PAM authentication.

    More info: https://github.com/HMAKT99/UnTouchID
  EOS
end
