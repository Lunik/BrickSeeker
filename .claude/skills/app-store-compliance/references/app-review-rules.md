# App Review rules that bite BrickScan

Distilled from the current App Store Review Guidelines and Apple developer docs (verified July 2026),
mapped to BrickScan's actual code. Numbering verified against the live sources below — re-check on major
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
- **Remaining scrape, deliberately kept, out of #111's scope:** resolving *which* BrickLink catalog item
  (type + number) a Rebrickable minifig/edge-case set id maps to still reads the item's Rebrickable page's
  "External Sites" table via `HeadlessWebScraper` (`BrickLinkPriceRepository.resolveMappedRef`) — neither
  BrickLink's API nor Rebrickable's API expose that mapping. Permanently cached per item
  (`BrickLinkMinifigIdStore`), so it runs once ever per item, not per price refresh, unlike the removed
  price-guide scrape which ran live on every `SetDetail` open. **Tracked in #117** as its own remediation,
  deliberately kept out of #111 to keep that PR scoped to the price-guide replacement — don't fold it back
  in without a dedicated issue/PR; see the feedback note in `AGENTS.md` about PR scope discipline.

### 2.3.1(a) — Hidden / undocumented features

> "Don't include any hidden, dormant, or undocumented features … functionality should be clear to end
> users and App Review."

- **Applies to:** the invisible `WKWebView` (`alpha 0.01`) + spoofed Safari UA. Never reintroduce.

### 5.2.1 — Intellectual property

- No third-party trademarks / copyrighted works without permission; no misleading names/metadata.
- **Applies to:** the word "LEGO" and LEGO/licensed trade dress in name, icon, splash, screenshots,
  keywords, and OS-facing strings. Nominative use in the description is fine with a disclaimer.

### 5.1.1 / 5.1.2 — Privacy, data disclosure

- Privacy policy link required **both** in App Store Connect metadata **and** inside the app.
- Disclose and, where needed, get consent before sending personal data to third parties.
- **Applies to:** `PrivacyDetailView`, `PrivacyNoticeView`, `PRIVACY.md`, ASC nutrition labels — must all
  match actual network behaviour.

### 2.1 — App completeness / demo access

- Final, tested build; **if the app needs a login or key to function, provide demo access** in Review Notes.
- **Applies to:** BrickScan is inert without a user-supplied Rebrickable API key → ship a dedicated reviewer
  account + key + step-by-step + a sample set number for manual entry (reviewers have no physical LEGO box).
- Also: no crash-on-launch. `try! ModelContainer` is a 2.1 risk (fixed in #105 phase 5).

### 4.8 — Login services

- **Not required here.** Exemption applies: BrickScan is a client for specific third-party services
  (Rebrickable / Brickset) that the user signs into directly. No Sign in with Apple needed.

### 2.5.6 — Web browsing uses WebKit

- Satisfied (the app uses WebKit). The scraping problem was 5.2.2 + 2.3.1(a), **not** 2.5.6.

### 3.1.3(e) — Physical goods

- Link-outs to buy physical LEGO sets are allowed **without** In-App Purchase. (Renumbered from an older
  3.1.5.)

## Platform / submission requirements (not in the guidelines doc)

- **Privacy manifest** (`PrivacyInfo.xcprivacy`) mandatory since May 2024. Required-reason API in this app:
  **UserDefaults → reason `CA92.1`**. No file-timestamp / disk-space / boot-time / active-keyboard APIs are
  used (re-grep if that changes).
- **SDK floor:** uploads must be built with **Xcode 26 / iOS 26 SDK** (since April 2026). Deployment target
  may stay iOS 17.
- **Age rating:** new questionnaire since Jan 2026; BrickScan expected **4+** (SFSafariViewController opening
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
| BrickLink API v3 (Store API, Price Guide) | Official REST API, user-supplied OAuth 1.0a consumer/token pair (own BrickLink dev account) | ToS (help.bricklink.com API Terms of Use, checked #111): requires an app to show a contact email + its own ToS/privacy policy, be solely responsible for its own support, and not replicate/circumvent BrickLink's checkout — none of which block a read-only personal price display; explicit prior authorization is required only to grant *other third parties* access through the app, which BrickScan doesn't do | If used |
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
