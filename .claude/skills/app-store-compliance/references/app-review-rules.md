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
  rebrickable.com HTML **violated this** (removed in #104).
- **Compliant paths:** official API with third-party-app ToS (Rebrickable ✅ ; BrickLink API — verify ToS),
  or visible `SFSafariViewController` link-out + manual entry (lego.com, amazon.fr).

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
| BrickLink API | Official API, OAuth 1.0a, user creds | **Verify ToS before shipping (#104)** | If used |
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
