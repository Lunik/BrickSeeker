# App Review rules that bite BrickSeeker

Distilled from the current App Store Review Guidelines and Apple developer docs (verified July 2026),
mapped to BrickSeeker's actual code. Numbering verified against the live sources below — re-check on major
guideline revisions.

## The rules, mapped to this app

### 5.2.2 — Third-party sites/services

> "If your app uses, accesses, monetizes access to, or displays content from a third-party service,
> ensure that you are specifically permitted to do so under the service's terms of use. Authorization
> must be provided upon request."

- **Applies to:** all price/data sources. Hidden-WKWebView scraping of lego.com / amazon.fr / bricklink.com /
  rebrickable.com HTML **violated this** (removed in #104). The BrickLink price-guide leg specifically was
  fixed in #111 (official Price Guide API, OAuth 1.0a) — see the authorisation record below.
- **Compliant paths:** official API with third-party-app ToS (Rebrickable ✅, BrickLink ✅ #111), or visible
  `SFSafariViewController` link-out + manual entry (lego.com, amazon.fr).
- **Minifig/edge-case-set id mapping — resolved in #117 (no scrape):** resolving *which* BrickLink catalog
  item (type + number) a Rebrickable minifig/edge-case set id maps to used to read the item's Rebrickable
  page's "External Sites" table via `HeadlessWebScraper`. It now uses **only official APIs**
  (`BrickLinkPriceRepository.resolveViaCatalogCrossReference`): Rebrickable part `external_ids.BrickLink`
  → BrickLink part *supersets* (intersected over printed/discriminant parts) → *subsets* composition check,
  permanently cached per item (`BrickLinkMinifigIdStore`). Neither API exposes the mapping directly, so it's
  reconstructed from part composition; the resolver favours precision over recall (~100% precision, ~53%
  recall, validated on a real collection) and abstains rather than risk a wrong price. The ~47% it can't
  resolve are the intended home for a future visible link-out + manual-entry fallback (Option 1).
- **Still open — `HeadlessWebScraper` itself remains** (used by `AmazonPriceScraper` + `LegoStoreRepository`
  for lego.com/amazon.fr HTML). #117 removed only the BrickLink-mapping caller; the Amazon/lego.com scrapes
  are a separate, still-open 5.2.2/2.3.1(a) gap (see hard rules) — don't treat the class as compliant just
  because #117 landed.

### 2.3.1(a) — Hidden / undocumented features

> "Don't include any hidden, dormant, or undocumented features … functionality should be clear to end
> users and App Review."

- **Applies to:** the invisible `WKWebView` (`alpha 0.01`) + spoofed Safari UA. Never reintroduce.
- **Also applies to background execution (#230).** An app that fetches data while closed must be honest
  about it: the `fetch` background mode and the `BGTaskSchedulerPermittedIdentifiers` entry are declared
  in `project.yml`, the behaviour is described in Réglages → « Surveillance des prix », and the last
  background pass is shown there. The background task calls **the BrickLink API only** — never a
  `WKWebView` source, which would be hard rule #1 *and* 2.3.1(a) at once (and cannot work anyway: no
  window in the background).

### 5.2.1 — Intellectual property

- No third-party trademarks / copyrighted works without permission; no misleading names/metadata.
- **Applies to:** the word "LEGO" and LEGO/licensed trade dress in name, icon, splash, screenshots,
  keywords, and OS-facing strings. Nominative use in the description is fine with a disclaimer.

### 5.1.1 / 5.1.2 — Privacy, data disclosure

- Privacy policy link required **both** in App Store Connect metadata **and** inside the app.
- Disclose and, where needed, get consent before sending personal data to third parties.
- **Applies to:** `PrivacyDetailView`, `PrivacyNoticeView`, `PRIVACY.md`, ASC nutrition labels — must all
  match actual network behaviour, **including what happens while the app is closed** (#230's background
  BrickLink pass is stated in all three in-app/repo surfaces).
- **Notifications (#229):** local only (`UNUserNotificationCenter`, no push entitlement, no APNs, no
  remote server). Nothing new to declare in the nutrition labels — no data leaves the device to produce
  them — but the in-app copy must not claim the app never notifies you, and no longer does.

### 2.1 — App completeness / demo access

- Final, tested build; **if the app needs a login or key to function, provide demo access** in Review Notes.
- **Applies to:** BrickSeeker is inert without a user-supplied Rebrickable API key → ship a dedicated reviewer
  account + key + step-by-step + a sample set number for manual entry (reviewers have no physical LEGO box).
- Also: no crash-on-launch. `try! ModelContainer` is a 2.1 risk (fixed in #105 phase 5).

### 4.8 — Login services

- **Not required here.** Exemption applies: BrickSeeker is a client for specific third-party services
  (Rebrickable / Brickset) that the user signs into directly. No Sign in with Apple needed.

### 2.5.6 — Web browsing uses WebKit

- Satisfied (the app uses WebKit). The scraping problem was 5.2.2 + 2.3.1(a), **not** 2.5.6.

### 3.1.3(e) — Physical goods

- Link-outs to buy physical LEGO sets are allowed **without** In-App Purchase. (Renumbered from an older
  3.1.5.)

## Platform / submission requirements (not in the guidelines doc)

- **Privacy manifest** (`PrivacyInfo.xcprivacy`) mandatory since May 2024. Required-reason API in this app:
  **UserDefaults → reason `CA92.1`**. No file-timestamp / disk-space / boot-time / active-keyboard APIs are
  used (re-grep if that changes). `BGTaskScheduler` and `UNUserNotificationCenter` (#229/#230) are **not**
  required-reason APIs — the manifest is unchanged by them.
- **Background modes** declared: `fetch` only, for `BGAppRefreshTask` id `com.lunik.brickseeker.priceRefresh`
  (#230). No `processing`, no location/audio background mode. Declared in `project.yml`, never in the
  generated `Info.plist`.
- **SDK floor:** uploads must be built with **Xcode 26 / iOS 26 SDK** (since April 2026). Deployment target
  may stay iOS 17.
- **Age rating:** new questionnaire since Jan 2026; BrickSeeker expected **4+** (SFSafariViewController opening
  fixed product pages is not an unrestricted web browser).
- **EU DSA trader status:** must be declared at first submission. Free, non-monetised app → **non-trader**
  available (trader status publishes the developer's address/phone/email publicly).
- **Export compliance:** OS-provided HTTPS/Keychain only → exempt; set `ITSAppUsesNonExemptEncryption=false`.

## Third-party API authorisation record

Keep this current — hard rule #1 requires a permission link for every automated data source.

| Service | Access method | ToS position | Attribution |
|---------|---------------|--------------|-------------|
| Rebrickable API v3 | Official REST API, user-supplied key | Permits app use, incl. commercial | "Data provided by Rebrickable" (appreciated) |
| Rebrickable CDN (images, CSV dumps) | Public downloads | Permitted | — |
| Brickset API v3 | Official API, user login → hash | App use allowed (verify rate limits) | If used |
| BrickLink API v3 (Store API, Price Guide) | Official REST API, user-supplied OAuth 1.0a consumer/token pair (own BrickLink dev account) | ToS (help.bricklink.com API Terms of Use, checked #111): requires an app to show a contact email + its own ToS/privacy policy, be solely responsible for its own support, and not replicate/circumvent BrickLink's checkout — none of which block a read-only personal price display; explicit prior authorization is required only to grant *other third parties* access through the app, which BrickSeeker doesn't do | If used |
| lego.com | **Visible link-out only** (no automated extraction) | Scraping prohibited | n/a |
| amazon.fr | **Visible link-out only** (PA-API needs affiliate + sales) | Scraping prohibited | n/a |

## Sources (verified July 2026)

- App Review Guidelines — https://developer.apple.com/app-store/review/guidelines/
- Privacy manifest files — https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- Required reason API — https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- Upcoming requirements — https://developer.apple.com/news/upcoming-requirements/
- Age ratings & DSA trader — https://developer.apple.com/help/app-store-connect/
- ITSAppUsesNonExemptEncryption — https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption
- App privacy details — https://developer.apple.com/app-store/app-privacy-details/
- Rebrickable API / ToS — https://rebrickable.com/api/ , https://rebrickable.com/terms/
- BrickLink API / ToS (#111) — https://www.bricklink.com/v3/api.page , https://help.bricklink.com/hc/en-us/articles/360034776133-API-Terms-of-Use
