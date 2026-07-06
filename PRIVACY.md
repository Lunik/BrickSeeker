# Politique de confidentialité — BrickScan

Dernière mise à jour : 2026-07-06

BrickScan est une application iOS qui vous aide à scanner des boîtes de sets de briques, gérer votre collection Rebrickable et comparer des prix. Cette page décrit quelles données sont traitées, où elles sont stockées, et avec quels services elles transitent.

## Résumé

BrickScan ne fait fonctionner aucun serveur propre et ne collecte aucune donnée pour son propre compte. Toutes les données restent sur votre appareil, à l'exception des échanges strictement nécessaires avec les services tiers listés ci-dessous.

## Données stockées sur l'appareil

- **API Key Rebrickable**, **identifiants/API Key Brickset** et **identifiants API BrickLink** (consumer key/secret, token/token secret OAuth 1.0a) : dans le Keychain iOS, chiffré par Apple.
- **Historique des sets scannés** et **cache de votre collection** : dans la base SwiftData locale de l'application.
- **Position approximative des scans** (si vous activez cette option dans les réglages) : stockée uniquement sur l'appareil, supprimée dès qu'un set rejoint votre collection ou que l'historique est purgé.
- **Vos mots de passe Rebrickable et Brickset ne sont jamais stockés** : ils ne servent qu'une seule fois, au moment de la liaison de compte, pour obtenir un jeton de session.

## Services tiers contactés

BrickScan communique directement avec les services suivants, depuis votre appareil :

| Service | Raison | Données transmises |
|---|---|---|
| **Rebrickable** | Catalogue des sets, gestion de votre collection | Votre API Key ; identifiants uniquement lors de la liaison de compte |
| **Brickset** | Gestion de votre liste cadeaux | Votre API Key ; identifiants uniquement lors de la liaison de compte |
| **BrickLink** | Affichage des prix officiels du marché (neuf/occasion), via l'API officielle | Vos identifiants API BrickLink (OAuth 1.0a), si vous les renseignez dans les réglages |
| **lego.com** | Affichage du prix officiel d'un set | Aucun identifiant — simple consultation de page publique |
| **amazon.fr** | Affichage du prix marché | Aucun identifiant — simple consultation de page publique |
| **Service de localisation d'Apple** (`CLGeocoder`) | Conversion d'une position en ville approximative, si l'enregistrement de position est activé | Coordonnées GPS, traitées par les services Apple |

BrickScan n'utilise aucun service de suivi publicitaire ni d'analytics, et ne transmet aucune donnée à un tiers autre que ceux listés ci-dessus.

## Vos droits

- Vous pouvez révoquer l'accès de BrickScan à tout moment depuis vos paramètres Rebrickable, Brickset ou BrickLink.
- Le bouton « Réinitialiser BrickScan » (dans Réglages → Confidentialité & données) supprime l'API Key enregistrée et l'historique des sets scannés.
- Le bouton « Vider le cache » supprime les images, prix et listes mis en cache, sans toucher à votre clé API, votre compte ou votre historique de prix.

## Contact

Pour toute question sur cette politique, ouvrez une issue sur le dépôt GitHub du projet : https://github.com/Lunik/brickscan/issues

## Marque

LEGO® est une marque du groupe LEGO, qui ne sponsorise ni n'approuve cette application.
