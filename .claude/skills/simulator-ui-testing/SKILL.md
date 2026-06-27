---
name: simulator-ui-testing
description: Drive the BrickScan app inside the iOS Simulator by actually tapping the screen (not just simctl/scripted automation) — for features only observable through real UI interaction, like Siri/Shortcuts App Shortcuts, share sheets, or system dialogs. Use after `ios-build-test` succeeds, when `verify`/`run` need to click something simctl can't reach.
---

# Simulator UI testing — tapping the screen for real

`xcrun simctl` covers install/launch/screenshot, but it **cannot tap, type, or scroll**. Some
things can only be verified by actually clicking — e.g. an `AppShortcutsProvider` tile in the
Shortcuts app, a system permission dialog, or a `shortcuts://` deep link that doesn't resolve
(App Shortcuts aren't addressable by `shortcuts://run-shortcut?name=`, only user-saved Shortcuts
files are — don't waste time on that URL scheme for App Intents).

To actually tap, you need to take control of the Mac's screen and mouse — that's the
`mcp__computer-use__*` tool family, not `Bash`/`simctl`.

## Steps

1. Build and install on a **dedicated test simulator**, not whatever the user has booted (skill
   `ios-build-test` for the build itself):
   ```bash
   xcrun simctl create "BrickScanTest" "iPhone 17 Pro" "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
   xcrun simctl boot <UDID>
   xcodebuild -project BrickScan.xcodeproj -scheme BrickScan \
     -destination 'id=<UDID>' -derivedDataPath build_sim build 2>&1 | grep -E "error:|BUILD"
   xcrun simctl install <UDID> build_sim/Build/Products/Debug-iphonesimulator/BrickScan.app
   xcrun simctl launch <UDID> com.lunik.brickscan
   open -a Simulator --args -CurrentDeviceUDID <UDID>
   ```
   `build_sim/` is gitignored (`build_*`) — never commit it.

2. Request control of the Mac:
   ```
   mcp__computer-use__request_access(apps=["Simulator"], reason="...")
   ```
   The user must approve the dialog. If `screenshot` then errors with "Accessibility and Screen
   Recording permissions are required", that's a **separate, OS-level** grant the user has to
   flip in System Settings → Privacy & Security — `request_access` alone doesn't cover it. Tell
   the user exactly that and wait; don't try to script around it (osascript/System Events will
   also fail with the same permission gap and can't self-grant).

3. Screenshot, then click using **image-pixel coordinates from that screenshot** — the Simulator
   window position/size can shift between calls (window manager, display changes), so always
   take a fresh screenshot before clicking rather than reusing coordinates from an earlier one.

4. To see *why* a tap failed (not just that it failed), stream device logs in parallel, detached
   so it survives the Bash tool call returning:
   ```bash
   nohup xcrun simctl spawn <UDID> log stream --level debug \
     --predicate '(process == "BrickScan" OR subsystem == "com.apple.AppIntents")' \
     > /tmp/sim.log 2>&1 &
   disown
   ```
   Plain `&` inside a backgrounded Bash call gets killed with the parent — use `nohup ... &
   disown` or the log goes silent after a few lines.

## Known dead ends (don't re-discover these)

- `xcrun simctl openurl <UDID> "shortcuts://run-shortcut?name=..."` → `Le fichier n'existe pas.`
  for an **App Shortcut** (declared via `AppShortcutsProvider`). That URL scheme only finds
  user-saved `.shortcut` files in the Shortcuts library, not app-declared ones. Tap the tile in
  the Shortcuts app's UI instead.
- `AppIntents: Attempted to fetch Auto Shortcuts, but couldn't find the AppShortcutsProvider` —
  if this shows in the log right after tapping an App Shortcut tile, and the provider/intent are
  correctly in the same single app target (no extension split — check `project.yml`), this is a
  known iOS Simulator-only flakiness (https://developer.apple.com/forums/thread/710552), not a
  code bug. Relaunching the app, relaunching Shortcuts, and even a full `simctl shutdown` +
  `boot` do **not** reliably fix it. Don't chase it further — note it as unverifiable in
  Simulator and recommend a real-device check instead.

## Don't

- Don't try to drive the Simulator with `osascript`/AppleScript "tell application System Events
  to click" — it needs the same Accessibility permission gap as above and fails the same way,
  just with a less informative error.
- Don't reuse click coordinates across screenshots taken more than one action apart.
- Don't commit `build_sim/`/`build_*` derived-data directories.
