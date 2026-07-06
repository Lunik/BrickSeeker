---
name: app-screenshots
description: Capture, store and update the BrickSeeker app screenshots used in the repo (README/docs). Use when adding visuals to the repo, refreshing them, or after any UI change that alters the look of an already-captured screen. Enforces the hard rule that no LEGO copyrighted content is ever published.
---

# App screenshots — BrickSeeker

How to produce the screenshots shown in the repo (README / `docs/`), where they live, and when to
refresh them. Read the copyright rule first — it is the constraint that shapes everything else.

## ⛔ Hard rule: never publish LEGO copyrighted/trademarked content

BrickSeeker is an open-source repo, not affiliated with the LEGO Group, Rebrickable, BrickLink or
Amazon (see README disclaimer). **No screenshot committed to this repo may show LEGO copyrighted
or trademarked content.** Concretely, a publishable screenshot must NOT contain:

- a **set image/render** pulled from Rebrickable (`SetThumbnailView` / `CachedRemoteImage` / the
  SetDetail hero image) — these are copyrighted product renders;
- **LEGO box art** or any real set/box visible **in the camera** view;
- official **set photography**, minifigure art, or LEGO logos.

Set numbers/names as plain text are factual references, but when in doubt **leave them out** —
prefer empty states and neutral chrome over anything that puts LEGO IP on screen.

### Screens that are safe to capture (no LEGO IP)

- **Home** (`HomeView`) — title, activity/collection **stat cards** (just numbers), action
  buttons, scan button. Safe as long as no set thumbnails are rendered (Home shows none).
- **Scanner** (`ScannerView`) — in the **iOS Simulator the camera feed is blank/black** (no
  hardware camera), so the scanning overlay/reticle renders over an empty frame with **no box in
  view**. This is exactly what we want — capture it there, never on a real device pointed at a box.
- **Settings** (`SettingsView`) — API-key field, account linking, clear-cache. Blank out any real
  API key / email first (see "Sanitize" below).
- **Manual entry** (`ManualSetEntryView`) and other **empty/zero states**.

### Screens that inherently show LEGO IP — do NOT publish as-is

`SetDetailView`, `CollectionView`, `HistoryView` render set images and set data. **Do not commit
screenshots of these in their normal state.** Options, in order of preference:
1. Skip them — the safe screens above already convey the app.
2. Capture an **empty state** (e.g. History/Collection before anything is scanned/synced).
3. Only if a visual is truly needed: **redact** it — cover every set thumbnail/hero image (solid
   block, not a blur that can be reversed) before committing. Even then, avoid if you can.

If you are unsure whether a frame is clean, it isn't — don't commit it.

## Where screenshots live

- Store them under **`docs/screenshots/`** (create it if missing).
- Use **stable, descriptive filenames** so README links never break on refresh:
  `home.png`, `scanner.png`, `settings.png`, `manual-entry.png`.
- Reference them from a **`## Screenshots`** section in `README.md` (and nowhere else, so there's
  one place to keep in sync). Keep them reasonably sized (PNG, single device width).

## How to capture

1. Build and run in the Simulator first — follow the `ios-build-test` skill (xcodegen + xcodebuild),
   then boot/run the app. Use a **consistent device** every time (e.g. a fixed iPhone model) so all
   screenshots share the same frame size.
2. Navigate to a **safe** screen (see list above) in a **clean app state** (fresh install / no real
   credentials / no synced collection so no set thumbnails appear).
3. Capture the booted simulator:
   ```bash
   xcrun simctl io booted screenshot --type=png docs/screenshots/home.png
   ```
   Repeat per screen, writing to the stable filename for that screen.
4. **Sanitize** before committing: no real Rebrickable API key, no account email, no synced set
   data on screen. Re-shoot rather than edit pixels where possible.
5. Visually inspect every file against the hard rule above **before** `git add`. A clean repo
   history matters — don't commit an IP-laden screenshot and "fix it later" (it stays in history).

## When to update

Refresh a screenshot **in the same PR as the change that altered it**, whenever a code change
modifies the appearance of an already-captured screen, e.g.:

- layout/restyle of `HomeView`, `SettingsView`, `ScannerView`, or `ManualSetEntryView`;
- a new section/card/button added to a captured screen;
- renamed/retranslated labels visible in a captured screen;
- a theme/color/icon change affecting a captured screen.

Re-capture **only the affected screen(s)**, reuse the **same filename**, and confirm the new shot
still passes the hard rule. If a feature adds a brand-new safe screen worth showing, add it under
`docs/screenshots/` with a new stable name and link it from the README's Screenshots section.

If a feature would only be illustrable by a screen that shows LEGO IP, **do not** add that
screenshot — describe the feature in text instead.
