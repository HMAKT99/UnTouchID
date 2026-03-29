cask "touchbridge" do
  version "1.0.0"
  sha256 "16c159670e45a10a2c2a39c178f6aeeddc4b739ebba66e2bd4aa83da24c6efbb"

  url "https://github.com/HMAKT99/UnTouchID/releases/download/v#{version}/TouchBridge-0.1.0.pkg"
  name "TouchBridge"
  desc "Use your phone's fingerprint to authenticate on any Mac"
  homepage "https://github.com/HMAKT99/UnTouchID"

  depends_on macos: ">= :ventura"

  pkg "TouchBridge-0.1.0.pkg"

  uninstall script: {
              executable: "/bin/bash",
              args:       ["-c", "launchctl bootout gui/$(id -u)/dev.touchbridge.daemon 2>/dev/null; rm -f /usr/local/bin/touchbridged /usr/local/bin/touchbridge-test /usr/local/bin/touchbridge-nmh /usr/local/lib/pam/pam_touchbridge.so ~/Library/LaunchAgents/dev.touchbridge.daemon.plist"],
              sudo:       true,
            }

  zap trash: [
    "~/Library/Application Support/TouchBridge",
    "~/Library/Logs/TouchBridge",
  ]

  caveats <<~EOS
    TouchBridge has been installed.

    To get started:
      touchbridged serve --simulator    # test without phone
      sudo echo 'It works!'            # try it

    For phone auth:
      touchbridged serve --web          # any phone, no app install

    More info: https://github.com/HMAKT99/UnTouchID
  EOS
end
