# Homebrew Cask draft (M5). `brew uninstall` deletes the bundle but leaves the SMAppService BTM
# registration behind (research F7) — the `uninstall` stanza and the in-app "Uninstall helper"
# action both call the daemon's unregister path.
cask "xcodevault" do
  version "0.1.0"
  sha256 "REPLACE_WITH_dist/XCodeVault-0.1.0.dmg.sha256"

  url "https://github.com/OWNER/XCodeVault/releases/download/v#{version}/XCodeVault-#{version}.dmg"
  name "XCodeVault"
  desc "Honest accounting and safe relocation of Xcode/Simulator storage"
  homepage "https://github.com/OWNER/XCodeVault"

  depends_on macos: ">= :sonoma"

  app "XCodeVault.app"
  binary "#{appdir}/XCodeVault.app/Contents/MacOS/xcodevaultctl"

  uninstall launchctl: "com.xcodevault.helper",
            quit:      "com.xcodevault.app"

  zap trash: [
    "~/Library/Application Support/XCodeVault",
    "~/Library/Preferences/com.xcodevault.app.plist",
  ]

  caveats <<~EOS
    The privileged helper (for root-owned CoreSimulator caches) must be enabled once in
    System Settings ▸ General ▸ Login Items & Extensions. Everything else works without it.
  EOS
end
