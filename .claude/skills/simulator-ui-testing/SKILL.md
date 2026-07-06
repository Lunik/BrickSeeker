---
name: simulator-ui-testing
description: Drive the BrickSeeker app inside the iOS Simulator by actually tapping the screen (not just simctl/scripted automation) — for features only observable through real UI interaction, like Siri/Shortcuts App Shortcuts, share sheets, or system dialogs. Use after `ios-build-test` succeeds, when `verify`/`run` need to click something simctl can't reach.
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

1. Use the user's own **"iPhone 17 Pro"** simulator (whatever its current UDID is — check with
   `xcrun simctl list devices | grep "iPhone 17 Pro"`), not a freshly created dedicated one. The
   user prefers driving their already-booted device over a throwaway `BrickSeekerTest` device (skill
   `ios-build-test` for the build itself):
   ```bash
   xcrun simctl list devices | grep "iPhone 17 Pro"   # find <UDID>, boot it if Shutdown
   xcodebuild -project BrickSeeker.xcodeproj -scheme BrickSeeker \
     -destination 'id=<UDID>' -derivedDataPath build_sim build 2>&1 | grep -E "error:|BUILD"
   xcrun simctl install <UDID> build_sim/Build/Products/Debug-iphonesimulator/BrickSeeker.app
   xcrun simctl launch <UDID> com.lunik.brickseeker
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

   The user's Mac keyboard layout is **French AZERTY**, not QWERTY/ANSI. The `mcp__computer-use__type`
   tool sends text that can land wrong or empty in a simulator text field (observed: typing
   digits produced accented letters like `è`/`ç` instead, or dropped the input entirely). Digits
   in particular sit on the shifted position on AZERTY — type them with individual `key` calls
   using `shift+<digit>` (e.g. `shift+7` → `7`), not `type`. Verify with `zoom` on the text field
   after typing before proceeding, since silent mis-typing is easy to miss in a screenshot.

4. To read `print()`/`FileHandle.standardError.write` output during a debug session — not just
   structured `os_log`, which is all `log stream` reliably captures — relaunch the app with
   `xcrun simctl launch --console <UDID> <bundle-id>` (backgrounded via `nohup ... & disown`,
   redirected to a file) instead of a plain `launch`. Plain stdout `print()` from the app process
   does **not** reliably show up in `log stream`, even with a matching predicate.

5. To see *why* a tap failed (not just that it failed), stream device logs in parallel, detached
   so it survives the Bash tool call returning:
   ```bash
   nohup xcrun simctl spawn <UDID> log stream --level debug \
     --predicate '(process == "BrickSeeker" OR subsystem == "com.apple.AppIntents")' \
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
