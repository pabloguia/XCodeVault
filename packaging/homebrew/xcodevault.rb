# Homebrew Cask DRAFT (M5). Not installable and not meant to be: there is no release, the sha256 is
# a placeholder, and the owner segment of the URLs is intentionally not a registrable GitHub name —
# publishing a cask that points at an unclaimed org invites somebody to go and claim it.
#
# `brew uninstall` deletes the bundle but leaves the SMAppService BTM registration behind
# (research F7) — the `uninstall` stanza and the in-app "Uninstall helper" action both call the
# daemon's unregister path. That stanza is kept for when the helper is actually shipped; today the
# bundle contains no helper (see scripts/bundle-app.sh --with-helper).
cask "xcodevault" do
  version "0.1.0"
  sha256 "REPLACE_WITH_dist/XCodeVault-0.1.0.dmg.sha256"

  url "https://github.com/<owner>/XCodeVault/releases/download/v#{version}/XCodeVault-#{version}.dmg"
  name "XCodeVault"
  desc "Honest accounting and safe relocation of Xcode/Simulator storage"
  homepage "https://github.com/<owner>/XCodeVault"

  depends_on macos: ">= :sonoma"

  app "XCodeVault.app"
  binary "#{appdir}/XCodeVault.app/Contents/MacOS/xcodevaultctl"

  uninstall launchctl: "com.xcodevault.helper",
            quit:      "com.xcodevault.app"

  zap trash:  [
        "~/Library/Application Support/XCodeVault",
        "~/Library/Preferences/com.xcodevault.app.plist",
      ],
      # Root-owned, so it needs `delete:` (which sudoes) rather than `trash:`, and it is listed
      # separately because it is the one thing the helper leaves outside the app bundle. The daemon
      # itself is registered with SMAppService from `Contents/Library/LaunchDaemons`, so removing
      # the app removes the plist and the binary with it; this directory is not in the bundle.
      #
      # It holds `helper-mount-history` (issue #24): what the cleanup verb has observed at each
      # allowlisted target. Leaving it behind is not dangerous — a reinstall reading its own old
      # records is the conservative direction, it refuses rather than deletes — but a package that
      # says it zaps should not leave a root-owned directory on the machine.
      delete: [
        "/Library/Application Support/XCodeVault",
      ]

  # No caveat telling anyone to enable the privileged helper. It used to say exactly that, while
  # nothing in the shipped code ever connected to it — so following the instruction bought a root
  # Mach service in the global bootstrap namespace and no functionality whatsoever.
end
