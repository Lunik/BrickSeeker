# Pre-submission checklist — BrickScan

Run this top to bottom before every App Store / TestFlight submission (hard rule #7). Do not submit on
memory. `[ ]` items are gates; a failed gate blocks submission until fixed.

## A. Code & build

- [ ] `ios-build-test` passes: `** BUILD SUCCEEDED **` (Xcode 26 / iOS 26 SDK on the submitting Mac).
- [ ] No hidden `WKWebView` / no spoofed User-Agent / no third-party scraping in the binary:
      `strings <app binary> | grep -Ei "Safari/604|amazon\.fr|catalogPG\.asp|customUserAgent"` → empty.
      (Since #111, `bricklink`/`api.bricklink.com` **will** appear — that's the legitimate official
      Price Guide API client, not scraping; don't treat that string alone as a failure. `catalogPG.asp`
      — the old scraped price-guide page — is the actual thing that must be gone, along with any
      `rebrickable\.com/(sets|minifigs)/` scrape traffic — #111 also removed the Rebrickable-page
      scrape that used to resolve BrickLink minifig ids, see `app-review-rules.md`'s 5.2.2 entry.)
- [ ] No crash-on-launch path: `ModelContainer` creation is guarded (do/catch), not `try!`.
- [ ] `Signing.xcconfig` holds the real `DEVELOPMENT_TEAM` (gitignored); it is **not** in `project.yml`.

## B. Privacy

- [ ] `BrickScan/Resources/PrivacyInfo.xcprivacy` exists, passes `plutil -lint`, and is present at the
      built `.app` root.
- [ ] Every required-reason API in the code has a matching `NSPrivacyAccessedAPITypes` entry
      (current: UserDefaults → `CA92.1`). Re-grep for new ones.
- [ ] `NSPrivacyTracking=false`, `NSPrivacyTrackingDomains=[]` (no tracking SDKs present).
- [ ] In-app privacy copy (`PrivacyDetailView`, `PrivacyNoticeView`) names **every** third party actually
      contacted by the shipped feature set, and understates nothing.
- [ ] `PRIVACY.md` is published at a public URL; that URL is set in App Store Connect **and** linked in-app.
- [ ] ASC nutrition labels match the in-app copy and `PRIVACY.md`.

## C. Intellectual property / metadata

- [ ] No "LEGO" in app name, subtitle, keywords, icon, splash, or OS-facing strings
      (`NSCameraUsageDescription`, Siri phrases, App Intent titles).
- [ ] Icon/splash/screenshots contain no LEGO/licensed IP (set renders, box art, minifigs, licensed themes).
      Screenshots produced per the `app-screenshots` skill.
- [ ] Description: at most one nominative "LEGO®" mention + the non-affiliation disclaimer.
- [ ] Every automated data source has a ToS-permission entry in `app-review-rules.md`.

## D. App Store Connect

- [ ] Bundle id `com.lunik.brickscan` registered; app record created (name BrickScan, primary language FR).
- [ ] `ITSAppUsesNonExemptEncryption=false` (export compliance: exempt).
- [ ] Age rating questionnaire completed (expected 4+).
- [ ] EU DSA trader status declared (non-trader for a free app, unless the owner chooses otherwise).
- [ ] Support URL set.
- [ ] Storefront selection made.

## E. Review Notes (critical — 2.1)

- [ ] Dedicated **reviewer Rebrickable account + API key** provided in Review Notes.
- [ ] Step-by-step: enter the key in Settings → use a **sample set number** (e.g. 10307) via **manual entry**
      (the reviewer has no physical LEGO box to scan) → observe lookup, price card, link-outs.
- [ ] Note that Brickset/BrickLink linking is optional.
- [ ] Dry-run the notes on a clean simulator install with only the reviewer key before submitting.

## F. Device-only sanity (TestFlight)

- [ ] Camera OCR scan works on a real device.
- [ ] Location opt-in prompt + coarse location + scan map behave; off by default.
- [ ] Keychain data persists across reinstall; Reset clears everything.
