cask "touchbridge" do
  version "1.1.0"
  sha256 "282e820fe499823c47810061398d17b9b3629c9cfbbbdb8be3e47edcffa58f7c"

  url "https://github.com/HMAKT99/UnTouchID/releases/download/v#{version}/TouchBridge-#{version}.pkg"
  name "TouchBridge"
  desc "Use your phone's Face ID or fingerprint to authenticate on any Mac"
  homepage "https://github.com/HMAKT99/UnTouchID"

  depends_on macos: ">= :ventura"

  pkg "TouchBridge-#{version}.pkg"

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

    Activate the sudo hook (shows a diff and asks before changing anything):
      sudo bash /usr/local/share/touchbridge/patch-pam.sh

    To get started:
      touchbridged serve --simulator    # test without phone
      sudo echo 'It works!'            # try it

    For phone auth:
      touchbridged serve --web          # any phone, no app install

    More info: https://github.com/HMAKT99/UnTouchID
  EOS
end
