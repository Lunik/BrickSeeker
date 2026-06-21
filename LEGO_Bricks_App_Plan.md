# BrickScan – Plan de développement complet
## Application iOS pour collectionneur LEGO avec intégration Rebrickable

---

## CONTEXTE & OBJECTIF

Développer une application iOS native (Swift/SwiftUI) appelée **BrickScan** permettant à un collectionneur LEGO de :
1. Scanner une boîte ou un manuel LEGO via la caméra de l'iPhone
2. Identifier automatiquement le numéro de set LEGO
3. Consulter si ce set est déjà dans sa collection Rebrickable
4. Ajouter le set à une liste Rebrickable, ou modifier la liste dans laquelle il se trouve

---

## PARTIE 1 — PRÉREQUIS & ENVIRONNEMENT

### 1.1 Outils requis

| Outil | Version minimale | Notes |
|---|---|---|
| Xcode | 16.0+ | Requis pour Swift 6, iOS 18 SDK |
| macOS | Sequoia 15.0+ | Requis par Xcode 16 |
| iPhone physique | iOS 17.0 minimum cible, iOS 18 recommandé | Le framework Vision ne fonctionne pas sur simulateur M1 pour certaines requêtes caméra |
| Apple Developer Account | Gratuit pour dev, payant ($99/an) pour TestFlight/App Store | |
| Compte Rebrickable | Avec API Key générée dans les settings du profil | |

### 1.2 Dépendances externes (Swift Package Manager uniquement)

Aucune dépendance tierce obligatoire. L'app utilise exclusivement des frameworks Apple natifs :
- **Vision** — détection barcode + OCR texte
- **AVFoundation** — flux caméra live
- **SwiftUI** — interface utilisateur
- **SwiftData** — persistance locale (cache sets + préférences)
- **Foundation URLSession** — appels API Rebrickable

### 1.3 Configuration Rebrickable

L'API Rebrickable v3 nécessite **deux niveaux d'authentification** :
- **API Key** : clé statique générée dans le profil Rebrickable (Settings → API Key). Utilisée pour toutes les requêtes en header `Authorization: key {API_KEY}`
- **User Token** : token dynamique obtenu en appelant `POST /api/v3/users/_token/` avec username + password. Nécessaire pour lire/modifier la collection de l'utilisateur.

L'URL de base de toutes les requêtes est : `https://rebrickable.com/api/v3/`

---

## PARTIE 2 — ARCHITECTURE GLOBALE

### 2.1 Pattern architectural

**MVVM + Repository Pattern**

```
View (SwiftUI)
  └── ViewModel (ObservableObject / @Observable)
        └── Repository (protocol)
              ├── RebrickableRepository (API calls)
              └── LocalRepository (SwiftData cache)
```

### 2.2 Structure des dossiers Xcode

```
BrickScan/
├── App/
│   ├── BrickScanApp.swift          # Point d'entrée, injection du ModelContainer SwiftData
│   └── AppEnvironment.swift        # Singleton d'environnement (clés, tokens)
│
├── Features/
│   ├── Auth/
│   │   ├── AuthView.swift
│   │   ├── AuthViewModel.swift
│   │   └── KeychainService.swift
│   │
│   ├── Scanner/
│   │   ├── ScannerView.swift       # Vue caméra principale
│   │   ├── ScannerViewModel.swift
│   │   ├── CameraPreviewView.swift # UIViewRepresentable wrapping AVCaptureSession
│   │   └── ScanOverlayView.swift   # UI overlay (cadre de scan, feedback)
│   │
│   ├── SetDetail/
│   │   ├── SetDetailView.swift
│   │   ├── SetDetailViewModel.swift
│   │   └── ListPickerView.swift    # Picker pour choisir la liste cible
│   │
│   └── Collection/
│       ├── CollectionView.swift    # Vue liste de sa collection (optionnel MVP)
│       └── CollectionViewModel.swift
│
├── Core/
│   ├── Network/
│   │   ├── RebrickableAPI.swift    # Définition des endpoints
│   │   ├── NetworkClient.swift     # URLSession wrapper
│   │   └── APIModels.swift         # Structs Codable des réponses API
│   │
│   ├── Repository/
│   │   ├── RebrickableRepository.swift
│   │   └── LocalRepository.swift
│   │
│   ├── Scanner/
│   │   ├── BarcodeScanner.swift    # Logique Vision barcode
│   │   ├── OCRScanner.swift        # Logique Vision OCR texte
│   │   └── SetNumberExtractor.swift # Parsing du numéro de set depuis OCR
│   │
│   └── Storage/
│       ├── KeychainService.swift
│       └── SwiftDataModels.swift   # @Model classes pour SwiftData
│
├── Resources/
│   ├── Assets.xcassets
│   └── Info.plist
│
└── Tests/
    ├── BrickScanTests/
    │   ├── SetNumberExtractorTests.swift
    │   └── RebrickableRepositoryTests.swift
    └── BrickScanUITests/
```

---

## PARTIE 3 — FONCTIONNALITÉS & FLOWS DÉTAILLÉS

### 3.1 Flow d'authentification

**Écran Auth (AuthView)**

Champs affichés :
1. Champ texte : "Rebrickable API Key" (from profile settings)
2. Champ texte : "Nom d'utilisateur Rebrickable"
3. Champ texte sécurisé : "Mot de passe Rebrickable"
4. Bouton "Se connecter"
5. **Bloc de transparence** (voir section dédiée ci-dessous) affiché juste sous les champs, avant le bouton

**Logique AuthViewModel :**

```
STEP 1 : Valider que les 3 champs sont non-vides
STEP 2 : Appeler POST https://rebrickable.com/api/v3/users/_token/
  - Header : Authorization: key {API_KEY}
  - Body (application/x-www-form-urlencoded) : username={username}&password={password}
  - Réponse attendue 200 : { "user_token": "abc123..." }
STEP 3 : Stocker dans Keychain :
  - clé "rebrickable_api_key" → valeur API_KEY
  - clé "rebrickable_user_token" → valeur user_token
  ⚠️ Le mot de passe n'est PAS stocké. Effacer immédiatement la variable Swift
     contenant le mot de passe après réception du user_token (assigner "").
     Le champ SecureField de SwiftUI est également vidé via le binding.
STEP 4 : Naviguer vers ScannerView
```

**Gestion des erreurs Auth :**
- 401 → Afficher : "API Key invalide"
- 403 → Afficher : "Nom d'utilisateur ou mot de passe incorrect"
- Réseau indisponible → Afficher : "Connexion impossible. Vérifiez votre réseau."

**Persistance de session :** Au lancement de l'app, vérifier si Keychain contient déjà les deux clés `rebrickable_api_key` et `rebrickable_user_token`. Si oui, naviguer directement vers ScannerView sans afficher AuthView.

---

**Bloc de transparence (PrivacyNoticeView) — composant réutilisable**

Ce composant est affiché directement dans AuthView, entre les champs et le bouton "Se connecter". Il n'est pas une modale, il est inline et toujours visible.

Structure visuelle :
```
┌─────────────────────────────────────────────────┐
│ 🔒  Vos données restent sur votre appareil       │
│                                                   │
│ • Votre mot de passe n'est jamais stocké.        │
│   Il est utilisé une seule fois pour obtenir     │
│   un token de session auprès de Rebrickable.     │
│                                                   │
│ • Seuls votre API Key et ce token sont           │
│   conservés, dans le Keychain iOS chiffré        │
│   par Apple.                                      │
│                                                   │
│ • Vous pouvez révoquer l'accès à tout moment     │
│   depuis vos paramètres Rebrickable.              │
│                                          [?]      │
└─────────────────────────────────────────────────┘
```

Implémentation :
- Background : `.secondarySystemBackground`, corner radius 12, padding 14
- Icône cadenas SF Symbol : `lock.shield.fill`, couleur `.green`
- Texte : `.footnote`, couleur `.secondary`
- Le bouton `[?]` en bas à droite ouvre une sheet `PrivacyDetailView`

**PrivacyDetailView (sheet modale)**

Titre : "Comment BrickScan protège vos données"

Contenu en 3 sections avec icônes SF Symbols :

```
Section 1 — "Ce qui est stocké" (icône: internaldrive)
  → API Key Rebrickable : dans le Keychain iOS
  → Token de session : dans le Keychain iOS
  → Sets scannés récemment : dans la base SwiftData locale, sur l'appareil uniquement

Section 2 — "Ce qui n'est jamais stocké" (icône: xmark.shield)
  → Votre mot de passe Rebrickable : effacé immédiatement après connexion
  → Aucune donnée n'est envoyée à un serveur tiers autre que Rebrickable

Section 3 — "Vous gardez le contrôle" (icône: hand.raised)
  → Lien tappable "Gérer votre API Key sur Rebrickable"
     → ouvre https://rebrickable.com/settings/ dans SFSafariViewController
  → Bouton "Se déconnecter" : supprime toutes les entrées Keychain et SwiftData,
     retourne sur AuthView
```

Le bouton "Se déconnecter" dans PrivacyDetailView déclenche :
```
KeychainService.delete("rebrickable_api_key")
KeychainService.delete("rebrickable_user_token")
SwiftData : supprimer tous les CachedSet et CachedSetList
Naviguer vers AuthView (reset de la NavigationStack)
```

Ce bouton "Se déconnecter" doit également être accessible depuis les Settings de l'app (un lien dans ScannerView → menu "..." → "Compte & Confidentialité").

---

### 3.2 Flow de scan

**ScannerView — Interface**

La vue affiche :
- Un flux caméra plein écran (AVCaptureSession)
- Un cadre rectangulaire centré indiquant la zone de scan (overlay SwiftUI)
- Un label en bas : "Pointez la caméra vers le code-barres ou le numéro de set"
- Un indicateur de statut en haut : "Scan en cours..." / "Set détecté !" / "Recherche..."
- Un bouton "Torche" (flashlight toggle) en haut à droite
- Un bouton "Historique" en haut à gauche (liste des derniers sets scannés, stockée localement)

**Architecture caméra :**

`CameraPreviewView` est un `UIViewRepresentable` qui encapsule un `AVCaptureSession`. Ne pas utiliser DataScannerViewController de VisionKit (moins de contrôle). Utiliser directement AVFoundation + Vision framework.

**Pipeline de détection (ScannerViewModel) :**

Le scanner tente **deux méthodes en parallèle** sur chaque frame caméra :

```
MÉTHODE A — Détection barcode (EAN-13 / EAN-8 / Code 128)
  ├── Utiliser VNDetectBarcodesRequest
  ├── Filtrer les symbologies : [.ean13, .ean8, .code128, .qr]
  ├── Si barcode détecté → extraire la valeur (ex: "5702016617756")
  └── Passer à SetNumberExtractor.extractFromBarcode(value)

MÉTHODE B — OCR texte (fallback si pas de barcode lisible)
  ├── Utiliser VNRecognizeTextRequest
  ├── recognitionLevel = .accurate
  ├── recognitionLanguages = ["en-US", "fr-FR"]
  ├── Collecter tous les candidats texte détectés
  └── Passer à SetNumberExtractor.extractFromOCR(candidates)
```

**SetNumberExtractor — Logique d'extraction :**

```swift
// EXTRACTION DEPUIS BARCODE
// Les boîtes LEGO utilisent EAN-13. L'EAN-13 encode le numéro de set LEGO
// mais l'EAN ne contient PAS directement le set number.
// Stratégie : utiliser l'EAN comme clé de recherche dans l'API Rebrickable
// GET /api/v3/lego/sets/?search={EAN_VALUE}
// Si aucun résultat, tenter GET /api/v3/lego/sets/{EAN_VALUE}-1/
// (certains anciens sets ont le numéro EAN comme set_num)

// EXTRACTION DEPUIS OCR
// Les boîtes et manuels LEGO affichent le numéro de set en format : XXXXX ou XXXXX-Y
// Exemples : "42143", "75192", "10300-1", "21325"
// Regex à appliquer sur chaque candidat texte :
// Pattern 1 : \b(\d{4,6})-?\d?\b  → numéro de 4 à 6 chiffres optionnellement suivi de -1, -2, etc.
// Pattern 2 : "Set No." ou "Art." suivi de chiffres (instructions manuels)
// Filtrer les faux positifs : ignorer les séquences qui ressemblent à des années (1990-2030),
// des codes EAN complets (13 chiffres), des numéros de téléphone
// Retourner la liste des candidats triés par confiance
```

**Anti-spam / déduplication :**

- Ne déclencher une recherche API qu'une fois par set number identique (debounce 1.5 secondes)
- Ne pas relancer si le même numéro a été identifié dans les 30 dernières secondes
- Mettre en pause le scan pendant qu'un SetDetailView est affiché

---

### 3.3 Flow SetDetail

**Déclenchement :** Quand SetNumberExtractor retourne un ou plusieurs candidats, ScannerViewModel :

1. Arrête le scan (pause AVCaptureSession)
2. Appelle l'API pour récupérer les données du set
3. Affiche SetDetailView

**Appels API pour récupérer le set :**

```
Tentative 1 : GET /api/v3/lego/sets/{set_num}-1/
  Header : Authorization: key {API_KEY}
  Si 200 → set trouvé, continuer
  Si 404 → Tentative 2

Tentative 2 : GET /api/v3/lego/sets/{set_num}/
  Si 200 → set trouvé, continuer
  Si 404 → Tentative 3

Tentative 3 : GET /api/v3/lego/sets/?search={set_num}&page_size=5
  Si results.count > 0 → afficher une liste de sélection (disambiguation)
  Si results.count == 0 → afficher "Set non trouvé. Essayez de scanner à nouveau."
```

**Modèle de données Set (APIModels.swift) :**

```swift
struct LegoSet: Codable, Identifiable {
    let setNum: String          // ex: "42143-1"
    let name: String            // ex: "Ferrari Daytona SP3"
    let year: Int               // ex: 2022
    let themeId: Int
    let numParts: Int
    let setImgUrl: String?      // URL image PNG
    let setUrl: String?         // URL page Rebrickable
    
    enum CodingKeys: String, CodingKey {
        case setNum = "set_num"
        case name
        case year
        case themeId = "theme_id"
        case numParts = "num_parts"
        case setImgUrl = "set_img_url"
        case setUrl = "set_url"
    }
}
```

**Vérification si le set est dans la collection :**

```
GET /api/v3/users/{user_token}/sets/{set_num}/
  Header : Authorization: key {API_KEY}
  Si 200 → le set EST dans la collection
    → Retourner l'objet UserSet contenant list_id et quantity
  Si 404 → le set N'EST PAS dans la collection
```

**Modèle UserSet :**

```swift
struct UserSet: Codable {
    let setNum: String
    let quantity: Int
    let incSpares: Bool
    let listId: Int?            // ID de la liste dans laquelle le set se trouve
    
    enum CodingKeys: String, CodingKey {
        case setNum = "set_num"
        case quantity
        case incSpares = "inc_spares"
        case listId = "list_id"
    }
}
```

**Interface SetDetailView :**

Afficher :
- Image du set (AsyncImage depuis set_img_url, placeholder générique si nil)
- Numéro de set (ex: 42143-1)
- Nom du set
- Année de sortie
- Nombre de pièces
- **Badge de statut** :
  - 🟢 "Dans votre collection" + nom de la liste si set présent
  - 🔴 "Pas dans votre collection" si absent
- **Boutons d'action** (selon statut) :
  - Si ABSENT : bouton principal "Ajouter à une liste" → ouvre ListPickerView
  - Si PRÉSENT : bouton "Changer de liste" → ouvre ListPickerView ; bouton secondaire "Retirer de la collection" (avec confirmation)
- Bouton "Scanner à nouveau" (ferme la vue, reprend le scan)
- Lien "Voir sur Rebrickable" (ouvre set_url dans Safari)

---

### 3.4 Flow ListPicker

**Récupération des listes utilisateur :**

```
GET /api/v3/users/{user_token}/setlists/
  Header : Authorization: key {API_KEY}
  Réponse : { "count": N, "results": [ { "id": 123, "name": "Ma collection", "num_sets": 42 }, ... ] }
```

**Modèle SetList :**

```swift
struct SetList: Codable, Identifiable {
    let id: Int
    let name: String
    let numSets: Int
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case numSets = "num_sets"
    }
}
```

**Interface ListPickerView :**

- Sheet modale présentée depuis SetDetailView
- Titre : "Choisir une liste"
- Liste scrollable des SetList de l'utilisateur (nom + nb de sets)
- Option en bas : "Créer une nouvelle liste" → champ texte inline pour saisir le nom
- Bouton "Confirmer" pour valider la sélection

**Actions selon le contexte :**

```
CAS 1 — Ajouter un set absent :
  POST /api/v3/users/{user_token}/sets/
    Header : Authorization: key {API_KEY}
    Body (application/x-www-form-urlencoded) :
      set_num={set_num}&quantity=1&list_id={selected_list_id}
    Succès 201 → Afficher toast "Set ajouté à {nom_liste}" + mettre à jour badge SetDetailView

CAS 2 — Changer de liste (set déjà présent) :
  PATCH /api/v3/users/{user_token}/sets/{set_num}/
    Header : Authorization: key {API_KEY}
    Body (application/json) : { "list_id": selected_list_id }
    Succès 200 → Afficher toast "Set déplacé vers {nom_liste}" + mettre à jour badge

CAS 3 — Créer une nouvelle liste puis y ajouter :
  STEP 1 : POST /api/v3/users/{user_token}/setlists/
    Body : name={nouveau_nom}
    Réponse 201 : { "id": new_id, "name": nouveau_nom }
  STEP 2 : Utiliser new_id comme selected_list_id dans CAS 1 ou CAS 2

CAS 4 — Retirer de la collection :
  DELETE /api/v3/users/{user_token}/sets/{set_num}/
    Succès 204 → Afficher toast "Set retiré de la collection" + mettre à jour badge
```

---

## PARTIE 4 — PERSISTANCE LOCALE (SwiftData)

### 4.1 Modèles SwiftData

```swift
// Cache local des sets récemment scannés
@Model
class CachedSet {
    @Attribute(.unique) var setNum: String
    var name: String
    var year: Int
    var numParts: Int
    var setImgUrl: String?
    var lastScannedAt: Date
    var isInCollection: Bool
    var currentListId: Int?
    var currentListName: String?
    
    init(from legoSet: LegoSet) { ... }
}

// Cache local des listes utilisateur
@Model
class CachedSetList {
    @Attribute(.unique) var listId: Int
    var name: String
    var numSets: Int
    var lastFetchedAt: Date
    
    init(from setList: SetList) { ... }
}
```

### 4.2 Stratégie de cache

- **CachedSet** : TTL de 24 heures. Si `lastScannedAt` > 24h, re-fetch depuis API.
- **CachedSetList** : TTL de 5 minutes. Re-fetch si expiré avant d'ouvrir ListPickerView.
- L'état "isInCollection" est toujours vérifié fraîchement via API (pas de cache) pour éviter les incohérences.

---

## PARTIE 5 — GESTION DES PERMISSIONS & SÉCURITÉ

### 5.1 Info.plist — Permissions requises

```xml
<key>NSCameraUsageDescription</key>
<string>BrickScan utilise la caméra pour scanner les boîtes et manuels LEGO</string>
```

### 5.2 Demande de permission caméra

Dans `ScannerViewModel.init()` :

```swift
AVCaptureDevice.requestAccess(for: .video) { granted in
    DispatchQueue.main.async {
        if granted {
            self.setupCaptureSession()
        } else {
            self.state = .permissionDenied
            // Afficher un message avec lien vers Settings de l'app
        }
    }
}
```

### 5.3 Sécurité des credentials

- API Key et User Token **uniquement** dans Keychain (jamais dans UserDefaults, jamais dans SwiftData, jamais loggués).
- Utiliser `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` comme accessibility attribute Keychain.
- KeychainService.swift expose uniquement `save(key:value:)`, `load(key:) -> String?`, `delete(key:)`.
- **Le mot de passe n'est JAMAIS stocké** : la variable Swift contenant le mot de passe est écrasée avec `""` immédiatement après réception du `user_token`. Le binding SwiftUI du SecureField est également vidé.
- Aucun appel réseau ne doit logger les headers en production (`#if DEBUG` guards sur tous les `print` contenant des credentials).
- `NetworkClient` ne doit jamais exposer l'API Key dans les messages d'erreur remontés à l'UI.

### 5.4 Nouveaux fichiers liés à la transparence

Les fichiers suivants sont ajoutés à la structure (dans `Features/Auth/`) :
- **`PrivacyNoticeView.swift`** : composant inline affiché dans AuthView (bloc cadenas vert, 3 bullets, bouton `[?]`)
- **`PrivacyDetailView.swift`** : sheet modale avec les 3 sections détaillées (ce qui est stocké / pas stocké / contrôle utilisateur) et le bouton "Se déconnecter"

Le bouton "Se déconnecter" de `PrivacyDetailView` est la **seule** fonction de déconnexion de l'app. Il est également accessible via `ScannerView` → bouton "..." (toolbar) → "Compte & Confidentialité" → `PrivacyDetailView`.

---

## PARTIE 6 — RÉSEAU & GESTION D'ERREURS

### 6.1 NetworkClient.swift

```swift
final class NetworkClient {
    static let shared = NetworkClient()
    private let baseURL = "https://rebrickable.com/api/v3"
    private let session = URLSession.shared
    
    func get<T: Codable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T
    func post<T: Codable>(path: String, body: [String: String]) async throws -> T
    func patch<T: Codable>(path: String, body: Codable) async throws -> T
    func delete(path: String) async throws
}
```

Tous les appels réseau utilisent `async/await`. L'API Key est injectée automatiquement dans le header `Authorization` de chaque requête depuis Keychain.

### 6.2 Gestion des erreurs réseau

Définir une enum `APIError` :

```swift
enum APIError: Error, LocalizedError {
    case unauthorized           // 401 - API Key invalide
    case forbidden              // 403 - User token invalide ou expiré
    case notFound               // 404 - Ressource inexistante
    case serverError(Int)       // 5xx
    case decodingError(Error)   // Parsing JSON échoué
    case networkUnavailable     // Pas de connexion
    case rateLimited            // 429 - Trop de requêtes
}
```

En cas de **403 sur un appel user token** (token expiré), re-déclencher automatiquement l'auth flow pour obtenir un nouveau token avec les credentials Keychain existants, puis réessayer la requête une fois.

### 6.3 Rate limiting

Rebrickable ne publie pas de limite officielle mais impose des limites. Implémenter :
- Un délai minimum de 200ms entre deux requêtes consécutives (RequestThrottler)
- En cas de 429, retenter après `Retry-After` header secondes (défaut : 5s)

---

## PARTIE 7 — INTERFACE UTILISATEUR DÉTAILLÉE

### 7.1 Navigation

Structure de navigation `NavigationStack` racine :

```
AuthView (si pas de credentials Keychain)
  └── ScannerView (vue principale)
        ├── SetDetailView (sheet/navigation push au scan)
        │     └── ListPickerView (sheet depuis SetDetailView)
        └── HistoryView (sheet depuis bouton Historique)
```

### 7.2 Design tokens

- **Couleur primaire** : `#E3000B` (rouge LEGO officiel)
- **Couleur secondaire** : `#FFD700` (jaune LEGO officiel)
- **Background** : `.systemBackground` (adaptatif dark/light mode)
- **Font** : SF Pro (système) — pas de font custom pour rester dans les guidelines Apple
- **Corner radius** : 12pt pour les cards, 8pt pour les boutons
- **Espacement standard** : 16pt

### 7.3 États de la ScannerView

La ScannerView gère les états suivants (enum `ScannerState`) :

```swift
enum ScannerState {
    case scanning           // En attente de scan, caméra active
    case processing         // Numéro détecté, requête API en cours (spinner)
    case found(LegoSet, UserSet?)  // Set identifié, afficher SetDetailView
    case ambiguous([LegoSet])      // Plusieurs sets possibles → picker
    case notFound           // Aucun set correspondant
    case error(APIError)    // Erreur réseau
    case permissionDenied   // Accès caméra refusé
}
```

### 7.4 Feedback visuel scan

- **Barcode détecté** : flash bref vert sur le cadre de scan + haptic `.notificationOccurred(.success)`
- **Texte détecté** : cadre de scan jaune pendant l'OCR
- **Chargement** : ProgressView centré sur l'overlay
- **Erreur** : cadre rouge + message d'erreur en bas avec bouton "Réessayer"

---

## PARTIE 8 — CONFIGURATION XCODE

### 8.1 Paramètres de la Target

- **Bundle Identifier** : `com.{yourname}.brickscan`
- **Deployment Target** : iOS 17.0
- **Swift Version** : 6.0
- **Supported Destinations** : iPhone uniquement (désactiver iPad et Mac)
- **Orientation** : Portrait uniquement

### 8.2 Capabilities requises

Dans l'onglet "Signing & Capabilities" :
- **Keychain Sharing** : activer (groupe optionnel)

### 8.3 Build Settings

- `SWIFT_STRICT_CONCURRENCY` = `complete` (prépare pour Swift 6 concurrency)
- `ENABLE_PREVIEWS` = `YES`

---

## PARTIE 9 — TESTS

### 9.1 Tests unitaires (BrickScanTests)

**SetNumberExtractorTests.swift :**

```swift
// Tester avec au moins 20 cas :
// - "Set No. 42143" → "42143"
// - "75192-1" → "75192-1"
// - "Art.Nr. 21325" → "21325"
// - "© LEGO 2022 10300" → "10300"
// - "1-800-422-5346" → nil (numéro de téléphone)
// - "2024" → nil (année)
// - "5702016617756" → barcode (passer à la méthode barcode)
```

**RebrickableRepositoryTests.swift :**
- Mocker NetworkClient avec `URLProtocol` custom
- Tester les 3 tentatives de recherche de set
- Tester la gestion d'erreur 401, 403, 404
- Tester le retry automatique sur token expiré (403)

### 9.2 Tests UI (BrickScanUITests)

- Login avec credentials invalides → message d'erreur affiché
- Login réussi → navigation vers ScannerView
- Simulation de scan (injecter une image statique) → SetDetailView affiché

---

## PARTIE 10 — DÉPLOIEMENT

### 10.1 TestFlight (Beta)

1. Dans Xcode : Product → Archive
2. Distribute App → TestFlight & App Store
3. Upload vers App Store Connect
4. Dans App Store Connect → TestFlight → Ajouter testeurs internes

### 10.2 App Store (Production)

Prérequis avant soumission :
- [ ] Privacy Policy URL (même simple, obligatoire car l'app accède à la caméra et à un compte externe)
- [ ] Screenshots pour iPhone 6.7" et 6.1"
- [ ] Description de l'app en français et anglais
- [ ] Catégorie suggérée : "Utilities" ou "Lifestyle"
- [ ] Note d'âge : 4+ (aucun contenu sensible)

**Points de review particuliers à anticiper :**
- Justifier l'usage de la caméra dans le champ "Camera Usage Description" (déjà couvert en 5.1)
- L'app se connecte à un service tiers (Rebrickable) : c'est autorisé, pas de login "Sign in with Apple" requis car c'est un service tiers non-Apple

### 10.3 Versions cibles

- **v1.0 (MVP)** : Auth + Scanner + SetDetail + ListPicker
- **v1.1 (Post-MVP)** : HistoryView + recherche manuelle de set (champ texte) + filtres de collection
- **v2.0** : Scan de pièces individuelles via RebrickNet API de Rebrickable

---

## PARTIE 11 — ENDPOINTS API REBRICKABLE — RÉFÉRENCE COMPLÈTE

Tous les endpoints utilisés par l'app, avec méthode, URL, paramètres et réponse attendue :

### Auth

| # | Méthode | Endpoint | Body | Réponse succès |
|---|---|---|---|---|
| 1 | POST | `/users/_token/` | `username`, `password` (form-urlencoded) | `{ "user_token": "..." }` |

### LEGO Catalog (lecture publique)

| # | Méthode | Endpoint | Params | Réponse succès |
|---|---|---|---|---|
| 2 | GET | `/lego/sets/{set_num}/` | — | Objet LegoSet |
| 3 | GET | `/lego/sets/` | `search={query}&page_size=5` | `{ "count": N, "results": [...] }` |

### User Collection (authentifié avec user_token dans le path)

| # | Méthode | Endpoint | Body/Params | Réponse succès |
|---|---|---|---|---|
| 4 | GET | `/users/{user_token}/sets/{set_num}/` | — | Objet UserSet (200) ou 404 |
| 5 | POST | `/users/{user_token}/sets/` | `set_num`, `quantity=1`, `list_id` (form-urlencoded) | Objet UserSet (201) |
| 6 | PATCH | `/users/{user_token}/sets/{set_num}/` | JSON `{ "list_id": N }` | Objet UserSet (200) |
| 7 | DELETE | `/users/{user_token}/sets/{set_num}/` | — | 204 No Content |
| 8 | GET | `/users/{user_token}/setlists/` | — | `{ "count": N, "results": [...] }` |
| 9 | POST | `/users/{user_token}/setlists/` | `name` (form-urlencoded) | Objet SetList (201) |

**Note sur l'authentification des endpoints User :**
- Le `user_token` est dans le **path URL** (pas en header)
- L'API Key reste quand même requise en **header** : `Authorization: key {API_KEY}`
- Les deux sont donc nécessaires simultanément pour les endpoints `/users/{user_token}/...`

---

## PARTIE 12 — CHECKLIST COMPLÈTE POUR CLAUDE CODE

Ordre d'implémentation recommandé :

- [ ] **Phase 1** : Setup projet Xcode (target, capabilities, Info.plist)
- [ ] **Phase 2** : `KeychainService.swift` — save/load/delete credentials
- [ ] **Phase 3** : `NetworkClient.swift` — URLSession async/await wrapper avec injection API Key
- [ ] **Phase 4** : `APIModels.swift` — structs Codable (LegoSet, UserSet, SetList, UserToken)
- [ ] **Phase 5** : `RebrickableAPI.swift` — définition des endpoints (enum ou struct)
- [ ] **Phase 6** : `RebrickableRepository.swift` — implémentation de tous les appels (11 endpoints)
- [ ] **Phase 7** : `SwiftDataModels.swift` + `BrickScanApp.swift` avec ModelContainer
- [ ] **Phase 8** : `AuthView.swift` + `AuthViewModel.swift` (avec effacement immédiat du mot de passe post-token)
- [ ] **Phase 8b** : `PrivacyNoticeView.swift` (bloc inline dans AuthView) + `PrivacyDetailView.swift` (sheet modale avec bouton déconnexion)
- [ ] **Phase 9** : `SetNumberExtractor.swift` — regex + logique d'extraction
- [ ] **Phase 10** : `BarcodeScanner.swift` + `OCRScanner.swift` — Vision framework
- [ ] **Phase 11** : `CameraPreviewView.swift` — AVCaptureSession dans UIViewRepresentable
- [ ] **Phase 12** : `ScannerView.swift` + `ScannerViewModel.swift` — assemblage complet
- [ ] **Phase 13** : `SetDetailView.swift` + `SetDetailViewModel.swift`
- [ ] **Phase 14** : `ListPickerView.swift` — sheet avec fetch des listes + actions CRUD
- [ ] **Phase 15** : Tests unitaires (SetNumberExtractor + Repository avec mocks)
- [ ] **Phase 16** : Tests sur device physique + polish UI/UX

---

*Ce plan est conçu pour être donné directement à Claude Code. Chaque phase est indépendante et implémentable séquentiellement. Toutes les signatures de méthodes, structures de données et appels API sont spécifiés sans ambiguïté.*
