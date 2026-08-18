<p align="center">
  <img src="site/logo.png" alt="Logo iCloudPhoto2Nextcloud" width="128">
</p>

# iCloudPhoto2Nextcloud

Agent macOS de barre de menus qui synchronise votre photothèque iCloud vers un serveur [Nextcloud](https://nextcloud.com) via WebDAV. Aucune icône dans le Dock : l'application vit dans la barre de menus et travaille en arrière-plan.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![Xcode](https://img.shields.io/badge/Xcode-26%2B-147EFB)

---

## Fonctionnalités

- **Synchronisation en arrière-plan** : détection automatique des changements de la photothèque (PhotoKit) — ajouts, modifications, suppressions.
- **Originaux complets** : photos originales, rendus édités, Live Photos (paire HEIC/JPG + MOV), RAW/ProRAW, vidéos non compressées.
- **Upload en 2 phases** : indexation/déduplication en base locale (SwiftData), puis envoi avec progression réelle (`X / Total`).
- **Gros fichiers** : au-delà de 10 Mo, upload par morceaux de 5 Mo (WebDAV Chunked Upload v2 de Nextcloud).
- **4 uploads simultanés** pour accélérer les bibliothèques de milliers de photos.
- **Mode miroir (option)** : une photo supprimée localement est aussi supprimée sur Nextcloud.
- **Suppressions détectées hors connexion** : au lancement, un scan complet repère les photos supprimées pendant que l'app était fermée et nettoie le serveur.
- **Nouvel essai automatique** : en cas d'échecs, replanification avec backoff (60 s → 120 s → 240 s, 3 cycles max).
- **Pause / reprise** à tout moment, scan complet forcé à la demande.
- **Menu enrichi** : état de la sync, statistiques, miniatures des 10 dernières photos synchronisées, accès direct aux réglages Photos si l'autorisation manque.
- **Fenêtre Réglages & Logs** : test de connexion WebDAV, configuration, logs filtrables (200 dernières entrées).
- **Vérification de la sauvegarde** : scan manuel ou périodique (jour/semaine/mois) qui liste le contenu du serveur et détecte les fichiers **manquants** ou **tronqués** (taille incohérente). Les éléments endommagés sont **ré-uploadés automatiquement**.
- **Mise à jour automatique** : chaque build publie une release GitHub ; l'app vérifie les nouveautés au lancement ou depuis le menu, télécharge le binaire adapté à votre Mac, **vérifie son empreinte SHA-256** puis s'installe et redémarre toute seule.
- **Bilingue français/anglais** : détection automatique de la langue système — français si le système est en français, anglais sinon.

## Organisation sur le serveur

Les fichiers sont déposés dans :

```
<dossier cible>/yyyy/MM/<nom de fichier original>
```

Exemple avec le dossier cible par défaut `Photos/iCloud` :

```
Photos/iCloud/2026/08/IMG_1234.HEIC
Photos/iCloud/2026/08/IMG_1234.MOV   (vidéo de la Live Photo)
```

## Prérequis

- **macOS 14.0** ou plus récent.
- Un serveur **Nextcloud** accessible (y compris en HTTP auto-hébergé — un avertissement s'affiche alors dans les réglages).
- Un **mot de passe d'application** (app password) Nextcloud, pas votre mot de passe principal : *Réglages → Sécurité → Mot de passe d'application* dans votre instance.
- Pour compiler : **Xcode 26+** (le projet utilise `objectVersion = 77` et `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).

## Installation

Chaque build sur `main` publie une nouvelle [Release GitHub](https://github.com/nitatemic/iCloudPhoto2Nextcloud/releases/latest) avec les trois binaires (**non signés**) :

| Architecture | Téléchargement |
|---|---|
| Intel + Apple Silicon (recommandé) | [iCloudPhoto2Nextcloud-Universal.zip](https://github.com/nitatemic/iCloudPhoto2Nextcloud/releases/latest/download/iCloudPhoto2Nextcloud-Universal.zip) |
| Apple Silicon uniquement | [iCloudPhoto2Nextcloud-macOS-AppleSilicon-arm64.zip](https://github.com/nitatemic/iCloudPhoto2Nextcloud/releases/latest/download/iCloudPhoto2Nextcloud-macOS-AppleSilicon-arm64.zip) |
| Intel uniquement | [iCloudPhoto2Nextcloud-macOS-Intel-x86_64.zip](https://github.com/nitatemic/iCloudPhoto2Nextcloud/releases/latest/download/iCloudPhoto2Nextcloud-macOS-Intel-x86_64.zip) |

Les builds sont **non signés** : à la première ouverture, faites un clic droit sur l'app → *Ouvrir*, ou lancez `xattr -dr com.apple.quarantine "iCloudPhoto2Nextcloud.app"`.

## Configuration

1. Ouvrez le menu de la barre de menus → **Réglages & Logs…**.
2. Renseignez l'**URL du serveur** (ex. `https://cloud.exemple.dev` — le schéma `https://` est ajouté automatiquement s'il manque), le **nom d'utilisateur** et le **mot de passe d'application**.
3. Cliquez **Tester la connexion** pour valider l'accès WebDAV.
4. Ajustez le **dossier distant** (par défaut `Photos/iCloud`) et l'option **miroir** (suppression distante en cas de suppression locale).
5. **Enregistrez les réglages** : un scan complet démarre immédiatement.

Au premier lancement, macOS demande l'autorisation d'accès à la photothèque. Si elle est refusée, le menu propose un raccourci direct vers *Réglages Système → Confidentialité → Photos*.

## Compilation depuis les sources

```bash
# Build
xcodebuild -scheme iCloudPhoto2Nextcloud -destination 'platform=macOS' build

# Tests unitaires (rapides, sans UI)
xcodebuild test -scheme iCloudPhoto2Nextcloud -destination 'platform=macOS' \
  -only-testing:iCloudPhoto2NextcloudTests

# Un seul test
xcodebuild test -scheme iCloudPhoto2Nextcloud -destination 'platform=macOS' \
  -only-testing:iCloudPhoto2NextcloudTests/NextcloudConfigTests/testUsernameEncoding
```

Tests d'intégration contre un **vrai serveur Nextcloud** (ils sont silencieusement ignorés sans ces variables) :

```bash
TEST_NEXTCLOUD_URL=https://cloud.exemple.dev \
TEST_NEXTCLOUD_USER=utilisateur \
TEST_NEXTCLOUD_PASS=xxxx-xxxx-xxxx \
xcodebuild test -scheme iCloudPhoto2Nextcloud -destination 'platform=macOS' \
  -only-testing:iCloudPhoto2NextcloudTests
```

## Architecture

| Composant | Rôle |
|---|---|
| `SyncEngine` | Orchestrateur (`@MainActor @Observable`, singleton). Cycle en 2 phases, pause, statistiques, suppressions différées, essais automatiques. |
| `PhotoObserver` | Enveloppe PhotoKit : observation des changements (`PHPhotoLibraryChangeObserver`), extraction des originaux (Live Photos, RAW, vidéos) via `PHAssetResourceManager`. |
| `NextcloudWebDAVService` | Actor : MKCOL/PUT/DELETE, upload par morceaux > 10 Mo, cache des dossiers créés, retry sur conflit 409. |
| `SyncedAsset` / `SyncedResource` | Modèles SwiftData persistés sur disque (suivi local, déduplication, statuts `pending/syncing/synced/failed`). |
| `NextcloudConfig` | Configuration : mot de passe dans le **Keychain**, reste dans `UserDefaults` (clés `nc_*`). |
| Vues | `StatusMenuView` (menu), `ConfigurationWindow` (Réglages + Logs), `PhotoThumbnailView` (miniatures). |

### Concurrence

- Le `SyncEngine` vit sur le MainActor ; les uploads réseau sont **asynchrones et parallèles** (4 à la fois, `TaskGroup`).
- Un seul cycle de synchronisation à la fois : les événements PhotoKit reçus pendant un cycle déclenchent un **scan de suivi** en fin de cycle.
- Les suppressions locales détectées pendant un cycle sont **différées** pour éviter de supprimer des modèles encore référencés par la boucle d'upload.

## Sécurité & vie privée

- **Pas de sandbox macOS** : elle a été désactivée pour permettre à l'app de se remplacer elle-même lors des mises à jour automatiques. La photothèque et les autres ressources sensibles restent protégées par les demandes d'autorisation système (TCC) à la première utilisation.
- Le **mot de passe d'application est stocké dans le Keychain** (jamais dans iCloud, jamais dans les logs) ; la configuration reste locale.
- `NSAllowsArbitraryLoads` est activé pour supporter les instances auto-hébergées en HTTP : un avertissement explicite s'affiche dans les réglages quand l'URL commence par `http://`.
- Les **données d'ajustement internes de Photos** (retouches, format propriétaire Apple) ne sont **pas** envoyées : seuls les fichiers exploitables (original + rendu édité) partent sur le serveur.

## Limites connues

- En **accès limité à la photothèque** (mode « Photos sélectionnées »), le balayage des suppressions est désactivé (il serait trompeur sur un sous-ensemble d'assets).
- Les aperçus des **HEIC dans l'interface web de Nextcloud** dépendent de la configuration serveur (imagick/ffmpeg, tâche `preview:generate`).
- **Lancement au démarrage de la session** (optionnel) : l'agent démarre automatiquement à l'ouverture de session (SMAppService), activable dans les réglages.
- Les miniatures du menu concernent les 10 dernières photos **synchronisées** (pas toute la bibliothèque).

## Développement

- **Conventions de commits** : [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`, `ci:`, `docs:`, `chore:`…).
- **Localisation** : le français est la langue source (`Localizable.xcstrings`, clés françaises + traductions `en`) ; toute nouvelle chaîne doit être ajoutée en français avec sa traduction anglaise dans le catalogue.
- `AGENTS.md` contient les commandes vérifiées et les pièges du projet pour les agents IA.
- **CI** : `.github/workflows/build-macos.yml` construit trois zips non signés (universel, x86_64, arm64) sur `macos-26` avec Xcode 26 à chaque push sur `main`, puis les publie dans une nouvelle Release GitHub (tag `ci-<sha>`, marquée Latest).

---

« iCloudPhoto2Nextcloud » — vos photos iCloud, sauvegardées où vous voulez.
