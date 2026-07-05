# BrickScan — Revue de conformité App Store

> Revue réalisée en juillet 2026 sur l'ensemble du code de la branche par défaut, en vue de la première publication sur l'App Store (passage d'une licence Apple Developer gratuite à la licence payante).
>
> **Ce document est un état des lieux.** La remédiation est pilotée par deux issues :
> - **Phase 1 (scraping)** → #104
> - **Phases 2 à 6** → #105

## 1. Méthodologie

- Inventaire complet de la surface applicative : `project.yml`, `Info.plist`, entitlements, asset catalog, toutes les vues/features, App Intents, réseau.
- Audit réseau/confidentialité : tous les endpoints contactés, stockage des secrets, données collectées, dépendances tierces, manifeste de confidentialité, APIs à raison obligatoire (*required-reason APIs*).
- Numérotation et texte des règles **vérifiés sur les sources Apple en vigueur** (voir §5). Deux corrections par rapport à une lecture ancienne : les biens physiques sont désormais en **3.1.3(e)** (et non 3.1.5) ; le navigateur web relève de **2.5.6**.

## 2. Constats (par ordre de risque)

| # | Constat | Fichier(s) | Règle / exigence | Risque |
|---|---------|-----------|------------------|--------|
| 1 | **Scraping caché** : `WKWebView` invisible injecté dans la key window (`alpha = 0.01`) + **User-Agent Safari falsifié** pour contourner Cloudflare, sur lego.com / amazon.fr / bricklink.com / rebrickable.com (HTML) | `Core/Scraping/HeadlessWebScraper.swift:89,130-138`, `LegoStoreRepository.swift`, `AmazonPriceScraper.swift`, `BrickLinkPriceScraper.swift` | **5.2.2**, **2.3.1(a)**, 5.2.1 | **Rejet certain si détecté + risque juridique/ToS permanent** |
| 2 | **Aucun `PrivacyInfo.xcprivacy`** alors que `UserDefaults` (required-reason API) est utilisé | `ScanStatsStore.swift`, `ScanLocationService.swift`, `AppTheme.swift`, `CollectionPriceUpdater.swift` ; manifeste absent | Manifeste obligatoire (mai 2024) ; catégorie `NSPrivacyAccessedAPICategoryUserDefaults`, raison `CA92.1` | **Blocage certain à l'upload** |
| 3 | **Textes de confidentialité in-app inexacts** : « aucun serveur tiers autre que Rebrickable » alors que brickset.com (avec identifiants), lego.com, bricklink.com, amazon.fr et Apple CLGeocoder sont contactés | `Auth/PrivacyDetailView.swift:23`, `Auth/PrivacyNoticeView.swift:15` | 5.1.1, 2.3 | Rejet probable |
| 4 | **Pas de politique de confidentialité** (ni URL ASC, ni lien in-app) | — | 5.1.1 (les deux emplacements obligatoires) | **Rejet certain** |
| 5 | **Marque « LEGO » dans des chaînes système** (usage caméra, phrases Siri, titres d'intent) | `project.yml` (`NSCameraUsageDescription`), `App/Intents/BrickScanShortcuts.swift`, `CheckSetPriceIntent.swift` | 5.2.1, 4.1(c) | Possible (corrigeable en metadata) |
| 6 | **Icône/splash évoquant le trade dress LEGO** (briques rouges à tenons — art original) | `Assets.xcassets/AppIcon.appiconset`, `SplashIcon.imageset` | 5.2.1 | Faible (garder ; redesign si rejet) |
| 7 | **`try! ModelContainer`** au lancement → crash au premier écran si échec de migration SwiftData | `App/BrickScanApp.swift:21` | 2.1 | Possible (crash au lancement) |
| 8 | **App inutilisable sans clé API Rebrickable** fournie par l'utilisateur → le reviewer ne peut rien tester | flux global | 2.1 (compte démo requis) | **Rejet certain sans notes de review + clé démo** |
| 9 | **`ITSAppUsesNonExemptEncryption` absent** | `project.yml` | Export compliance (HTTPS seul → exempt, `false`) | Metadata |
| 10 | **Métadonnées App Store Connect à compléter** : nutrition labels, statut trader DSA, questionnaire d'âge (janv. 2026), URL de support, build **Xcode 26 / SDK iOS 26** (plancher depuis avril 2026 ; README dit « Xcode 16+ ») | ASC + `README.md` | Exigences ASC | Blocages de soumission |
| 11 | **Pas d'attribution Rebrickable in-app** | `SettingsView` | ToU Rebrickable (recommandé) | Faible |

## 3. Points déjà conformes (à préserver)

- **Aucun secret hardcodé** : la clé API Rebrickable et les tokens sont saisis par l'utilisateur et stockés en Keychain avec `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (non synchronisé iCloud). Le mot de passe Rebrickable/Brickset n'est **jamais** persisté (échangé une fois contre un token/hash).
- **OCR 100 % on-device** (Vision) : aucune image ni frame caméra n'est envoyée à un service distant ; seul le *numéro de set* extrait part vers l'API Rebrickable.
- **Localisation** strictement opt-in, désactivée par défaut, approximative (~100 m), one-shot par scan, supprimée quand un set rejoint la collection ou que l'historique est purgé.
- **Aucun SDK tiers, aucun tracking/analytics** ; frameworks Apple uniquement.
- **ATS** : tout en HTTPS, aucune exception `NSAllowsArbitraryLoads`.
- **Sign in with Apple non requis** : exemption 4.8 applicable (client d'un service tiers spécifique ; l'utilisateur se connecte directement à son compte Rebrickable/Brickset).
- **Liens d'achat de biens physiques** : autorisés sans achat intégré (3.1.3(e)).
- Stockage local uniquement (SwiftData sans CloudKit) ; cache image exclu de la sauvegarde iCloud.

## 4. Analyse détection vs. risque permanent (constat #1)

- **Ce que la review peut détecter** : ouvrir un détail de set déclenche du trafic vers amazon.fr / bricklink.com / lego.com à travers des challenges Cloudflare, visible avec un proxy ; l'UA falsifié et le JS d'extraction DOM sont des littéraux présents dans le binaire, repérables par analyse statique. Détection *possible à probable*, pas certaine.
- **Ce que la review ne peut pas neutraliser** : le dépôt est public et le README documente ouvertement le scraping par WKWebView caché. Même si la review passe, LEGO / Amazon peuvent lire le README et déposer une plainte à tout moment (les retraits d'app sur demande d'ayant droit sont routiniers), en plus de l'exposition ToS/anti-contournement permanente. Ce risque existe **indépendamment de l'App Review** — c'est pourquoi « désactivé mais présent dans le binaire » ou « gardé discrètement » ne sont pas des états finaux acceptables. La remédiation (#104) supprime le code de scraping et le remplace par des voies conformes.

## 5. Sources vérifiées

- App Review Guidelines — https://developer.apple.com/app-store/review/guidelines/
- Privacy manifest files — https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- Describing use of required reason API — https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- Upcoming requirements (SDK iOS 26) — https://developer.apple.com/news/upcoming-requirements/
- Age ratings (janv. 2026) — https://developer.apple.com/help/app-store-connect/
- DSA trader requirements — https://developer.apple.com/help/app-store-connect/manage-compliance-information/
- Export compliance / `ITSAppUsesNonExemptEncryption` — https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption
- App privacy details — https://developer.apple.com/app-store/app-privacy-details/
- Rebrickable API & ToS — https://rebrickable.com/api/ , https://rebrickable.com/terms/

## 6. Remédiation

Voir les issues de suivi :
- **#104** — Phase 1 : remplacer le scraping caché par une comparaison de prix conforme (API BrickLink officielle + liens visibles + saisie manuelle).
- **#105** — Phases 2-6 : privacy manifest, confidentialité, marques, robustesse, soumission ASC.

Le skill `.claude/skills/app-store-compliance/` capitalise ces règles pour les développements futurs et accumule les motifs de rejet réels (`references/rejection-log.md`).
