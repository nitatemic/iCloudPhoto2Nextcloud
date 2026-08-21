# AGENTS.md

## Project

macOS menu-bar agent (`LSUIElement`, no Dock icon) that syncs the iCloud Photo Library to a Nextcloud server over WebDAV. SwiftUI + SwiftData + PhotoKit, deployment target macOS 14.0, Swift 6 (strict concurrency). Plain `.xcodeproj` — no workspace, no Swift Package Manager dependencies.

- `project.pbxproj` uses `objectVersion = 77`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES` and `SWIFT_VERSION = 6.0` → **Xcode 26+ required** to open/build (CI broke on this before; see git history). Consequence: unannotated public top-level types are MainActor-isolated — public types that must stay general are marked `nonisolated` (e.g. `EngineState`, `NextcloudConfig`).
- **Known compiler bug (Swift 6.2/6.3, region-based isolation):** a `group.addTask` closure *explicitly annotated* `@MainActor` containing an `await` triggers `error: pattern that the region-based isolation checker does not understand to check. Please file a bug`. And an unannotated closure cannot touch MainActor state synchronously. The working pattern (see `SyncEngine.uploadChunk`): closures capture **only `Sendable` values** (e.g. `String` + `PersistentIdentifier`), are left unannotated (inherit the module's default MainActor… no — they are `@isolated(any)`; they must not touch MainActor members synchronously), and delegate all actor work to a MainActor `async` method (`processWorkItem`) that re-fetches the model objects on the MainActor. With a **non-Sendable** capture the same pattern fails with `sending parameter risks causing data races` — so never capture `PHAsset`/`@Model` instances into task-group closures.
- Localization: `Localizable.xcstrings` (source language = **French keys** + `en` translations) and `InfoPlist.xcstrings` (photo permission text). `CFBundleDevelopmentRegion` is `en` so the fallback is: French system → French, **any other language → English**. Runtime language is driven by the system language — the `locale:` parameter of `String(localized:)` does **not** switch languages. New strings: add the French key + an `en` entry to the catalog.

## Build & Test (verified commands)

```bash
# Build
xcodebuild -scheme iCloudPhoto2Nextcloud -destination 'platform=macOS' build

# Unit tests only (fast, no UI runner)
xcodebuild test -scheme iCloudPhoto2Nextcloud -destination 'platform=macOS' \
  -only-testing:iCloudPhoto2NextcloudTests

# Single test
xcodebuild test -scheme iCloudPhoto2Nextcloud -destination 'platform=macOS' \
  -only-testing:iCloudPhoto2NextcloudTests/SwiftDataCatalogTests/testSyncedAssetCatalog
```

No linter/formatter/typecheck config exists in the repo — `xcodebuild` is the only verification gate.

## Testing quirks

- The unit-test bundle is **app-hosted** (`TEST_HOST` = the app): running unit tests launches the app, so `SyncEngine.shared.startEngine()` runs and the PhotoKit permission prompt can appear on first run.
- Test target mixes **XCTest and Swift Testing** (`@Test`/`#expect`) in the same bundle.
- `LiveNextcloudIntegrationTests` hits a **real Nextcloud server** and silently skips (passes) unless `TEST_NEXTCLOUD_URL`, `TEST_NEXTCLOUD_USER`, `TEST_NEXTCLOUD_PASS` are set in the environment. A green run does not mean the live path was exercised.
- `NextcloudConfigTests/testKeychainManager` reads/writes the **real macOS Keychain** (service `com.icloudphoto2nextcloud.credentials`).

## Architecture

- `SyncEngine` (`@MainActor @Observable` singleton, `SyncEngine.shared`) is the orchestrator; started in `iCloudPhoto2NextcloudApp.init()`. Two-phase sync: index/dedupe against SwiftData, then upload with progress. Phase 2 uploads in bounded chunks of `maxConcurrentUploads` (4); each chunk goes through `SyncEngine.uploadChunk` + `processWorkItem` (see the concurrency note above).
- **Backup integrity verification** (`performIntegrityVerification`): manual (menu/settings) or scheduled (config `autoVerifyEnabled` + `verifyIntervalDays`, hourly scheduler task `restartVerificationScheduler` — checks due state in `checkScheduledVerification`). Reuses `isSyncingInProcess` mutual exclusion + `finishSyncCycle`; engine state `.verifying`. Logic: one PROPFIND Depth:1 per `yyyy/MM` folder in the local DB (`webDavService.listDirectory`, XML parsed by `NextcloudWebDAVService.parseMultistatusResponse`), then pure comparison in `BackupVerifier.evaluateVerification` (Sendable inputs, unit-testable). Damaged assets (missing or size mismatch) are marked `failed` and re-uploaded by a follow-up sync; untracked server files (orphans) are only logged, never deleted. `lastVerificationDate` persists in `UserDefaults` (`nc_last_verification`).
- `PhotoObserver` wraps PhotoKit (`PHPhotoLibraryChangeObserver`, `PHAssetResourceManager` extraction of originals, Live Photo HEIC+MOV pairs, videos).
- `NextcloudWebDAVService` (`actor`): MKCOL/PUT/DELETE; files >10 MB are chunked in 5 MB parts. `NSAllowsArbitraryLoads` is enabled in Info.plist to support self-hosted instances.
- Persistence: SwiftData models `SyncedAsset` / `SyncedResource` (both in `SyncedAsset.swift`), stored on disk (not in-memory). Remote layout: `<targetFolder>/yyyy/MM/<originalFilename>`.
- `NextcloudConfig` split: `NextcloudConfig.loadFromKeychain()/saveToKeychain()` actually stores the app password in the Keychain and everything else in `UserDefaults` (`nc_*` keys). Browser sign-in (`NextcloudLoginFlow`, `nonisolated enum`): Nextcloud login flow v2 (fallback v1 for NC < 20) — `POST /index.php/login/flow/v2` with `client_name` → open `login` URL in browser (`NSWorkspace.shared.open`) → poll (v2: POST, 404 = pending; v1: GET, 202 = pending) until `{ server, loginName, appPassword }`; credentials land in the same Keychain slot, device appears in Settings → Security. Flow is cancelable via task cancellation; poll caps at 9 min (Nextcloud token TTL ~10 min).
- Launch at login uses `SMAppService.mainApp` (`import ServiceManagement`) — the toggle lives in `SettingsView` and applies immediately on change; `register()` fails (and the toggle reverts, with a log) when the app is not in `/Applications`, e.g. when run from Xcode.
- **Auto-update** (`AppUpdater`, `nonisolated enum`, no state): GitHub `releases/latest` API; each CI build stamps `CFBundleVersion = <commit count>` (PlistBuddy before `ditto` in the workflow — auto-increments on every push) and `CIBuildTag = ci-<sha>` so the app can compare its own build tag to the latest release tag (`currentBuildTag` reads `CIBuildTag`, legacy fallback to a `ci-`-prefixed `CFBundleVersion`; `checkForUpdate`, fallback: `nc_installed_release_tag`). Binary picked by `selectAsset` (AppleSilicon/Intel, universal fallback); the release body carries a markdown table `| file | arch | sha256 |` generated by the workflow, and the SHA-256 is **verified** (CryptoKit) before install (`checksumMismatch` refusal). Install = move current bundle aside → copy new → relaunch via `open -n` + terminate (`replaceBundle`/`relaunch`); fails gracefully if `/Applications` not writable (`destinationNotWritable`). Manual check in the menu (NSAlert confirm), optional launch check (`nc_check_updates_on_launch`). **Not localizable via `String(localized:)` with format args — use interpolation** (see `UpdateError`). Unit tests: asset selection, body hash extraction, JSON decoding, update error descriptions — no network.
- **App is NOT sandboxed anymore** (entitlements = `personal-information.photos-library` only): the sandbox was removed so the app can replace its own bundle during auto-update. Photo/permission flows (TCC) are unchanged; changing entitlements requires updating `iCloudPhoto2Nextcloud.entitlements`.

## Conventions

- Commit style: Conventional Commits (`feat:`, `fix(ci):`, `ci:`, `docs:`).
- Spec-driven planning docs live in `docs/superpowers/specs/` and `docs/superpowers/plans/` (dated files); `.superpowers/` is tooling state, content gitignored.
- Security scan: `snyk code test` (SAST). `.snyk` exclut `iCloudPhoto2NextcloudTests` (fixtures factices) — les ignores par ID de finding ne fonctionnent PAS pour Snyk Code ; les 2 faux positifs MEDIUM de `NextcloudConfig.swift` (nom de clé Keychain) sont ignorés côté serveur via Consistent Ignores (`snyk ignore create`).

## CI

Single workflow `.github/workflows/build-macos.yml` (push to `main` + manual): builds three **unsigned** Release zips (universal, x86_64, arm64) on `macos-26` (arm64) with `maxim-lobanov/setup-xcode` pinned to `xcode-version: '26'`. The `CODE_SIGN_IDENTITY=""` / `CODE_SIGNING_REQUIRED=NO` / `CODE_SIGNING_ALLOWED=NO` overrides in each `xcodebuild` invocation are load-bearing — builds fail on the runner without them. `macos-latest` still maps to macOS 15, so keep the explicit `macos-26` label. Each run also **publishes a GitHub Release** (`softprops/action-gh-release`, tag `ci-<sha>`, `make_latest: true`, `permissions: contents: write`) — README download links use the stable `releases/latest/download/` URLs, so they always point to the newest build.
