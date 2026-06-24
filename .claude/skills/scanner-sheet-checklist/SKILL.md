---
name: scanner-sheet-checklist
description: Checklist for adding any new sheet, picker, or text-entry surface to ScannerView (or a similar full-screen camera view). Use whenever you add a new `.sheet`/`.photosPicker`/overlay to ScannerView, or a new text-input view presented over the camera.
---

# Adding a new sheet/picker to ScannerView

`ScannerView` is a full-screen camera view with several things layered on top of it (History,
Settings, manual entry, the set-detail/ambiguous-set sheets, the Photos picker). Every new
addition in this family has hit the same handful of gotchas — check all of these before
considering the change done.

## 1. Camera lifecycle — add to `isMenuOpen`

The capture session must stop while anything covers it, or the camera keeps running (wasted
battery/CPU, and Vision keeps firing on frames nobody sees). `ScannerView.isMenuOpen` is the
single source of truth feeding the `.onChange(of: isMenuOpen)` that starts/stops
`viewModel.cameraController`. Add your new `@State` presented-flag (or state-derived `Binding`)
to that computed property's `||` chain. Don't add a separate one-off `.onChange` for your sheet —
it'll fight with the existing one over who controls the camera.

## 2. Text input — focus immediately

If the new surface has a `TextField` (manual entry, search, rename, etc.), the keyboard should
already be up when the sheet appears — don't make the user tap the field first. Pattern (see
`ManualSetEntryView` in `ScannerView.swift`):

```swift
@FocusState private var isInputFocused: Bool
...
TextField(...)
    .focused($isInputFocused)
...
.onAppear { isInputFocused = true }
```

## 3. Collection-state mutation — sync the SwiftData cache

If the new surface can change a set's real collection/list status (add to list, remove from
collection, retry status), `HistoryView`'s `CachedSet` won't update on its own — it reads from
SwiftData via `LocalRepository`, not from any view model directly. Call
`LocalRepository(modelContext:).cacheSet(...)` again after the mutation completes. `SetDetailView`
does this via `.onChange(of: viewModel.collectionStatus)` calling a local `syncCache()` — follow
that pattern rather than inventing a new one.

## 4. Audio/visual feedback — visual at detection, sound once in `resolveSet`

If your change touches scan feedback timing, mind the split:

- **Visual** (the pulsing-green/checkmark overlay) fires at detection: `candidateDetected = true`
  in `scheduleResolution`, so it matches what the user is looking at.
- **Sound** (`ScanFeedback.playCandidateDetectedSound()`) fires inside `resolveSet`, **not** at
  detection. It used to be at detection, but `scheduleResolution` re-runs for the same in-view
  candidate on every throttled frame, which made the sound repeat every ~0.8s. `resolveSet`
  (guarded by `lastIdentifiedSetNum`/`lastIdentifiedAt`) is the one point that runs once per
  resolved candidate. Don't move it back to detection without fixing that repeat-fire.

Both are gated by `ScannerViewModel.playsFeedbackSounds` (Home's non-camera `lookupViewModel`
sets it `false`). Check `ScanFeedback.swift` / `AGENTS.md`'s "Scanning pipeline" section before
changing any of this.

## 5. Build & test

Run the `ios-build-test` skill's steps before reporting done — adding a sheet means a new file
for xcodegen to pick up if it's its own file, and UI-only changes have caused real regressions
here before (camera not stopping, stale cache) that only show at test/manual-run time.
