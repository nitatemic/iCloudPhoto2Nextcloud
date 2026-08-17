# AGENTS.md

## Project

macOS menu-bar agent (`LSUIElement`, no Dock icon) that syncs the iCloud Photo Library to a Nextcloud server over WebDAV. SwiftUI + SwiftData + PhotoKit, deployment target macOS 14.0, Swift 5. Plain `.xcodeproj` — no workspace, no Swift Package Manager dependencies.

- `project.pbxproj` uses `objectVersion = 77` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` → **Xcode 26+ required** to open/build (CI broke on this before; see git history).
- All user-facing strings, logs, and error messages are in **French**. Keep new UI/log strings in French.

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

- `SyncEngine` (`@MainActor @Observable` singleton, `SyncEngine.shared`) is the orchestrator; started in `iCloudPhoto2NextcloudApp.init()`. Two-phase sync: index/dedupe against SwiftData, then upload with progress.
- `PhotoObserver` wraps PhotoKit (`PHPhotoLibraryChangeObserver`, `PHAssetResourceManager` extraction of originals, Live Photo HEIC+MOV pairs, videos).
- `NextcloudWebDAVService` (`actor`): MKCOL/PUT/DELETE; files >10 MB are chunked in 5 MB parts. `NSAllowsArbitraryLoads` is enabled in Info.plist to support self-hosted instances.
- Persistence: SwiftData models `SyncedAsset` / `SyncedResource` (both in `SyncedAsset.swift`), stored on disk (not in-memory). Remote layout: `<targetFolder>/yyyy/MM/<originalFilename>`.
- Config split (misleading names): `NextcloudConfig.loadFromKeychain()/saveToKeychain()` actually store the app password in the Keychain and everything else in `UserDefaults` (`nc_*` keys).
- App is sandboxed: entitlements = app-sandbox + network.client + photos-library. Changing entitlements requires updating `iCloudPhoto2Nextcloud.entitlements`.

## Conventions

- Commit style: Conventional Commits (`feat:`, `fix(ci):`, `ci:`, `docs:`).
- Spec-driven planning docs live in `docs/superpowers/specs/` and `docs/superpowers/plans/` (dated files); `.superpowers/` is tooling state, content gitignored.

## CI

Single workflow `.github/workflows/build-macos.yml` (push to `main` + manual): builds three **unsigned** Release zips (universal, x86_64, arm64) on `macos-26` (arm64) with `maxim-lobanov/setup-xcode` pinned to `xcode-version: '26'`. The `CODE_SIGN_IDENTITY=""` / `CODE_SIGNING_REQUIRED=NO` / `CODE_SIGNING_ALLOWED=NO` overrides in each `xcodebuild` invocation are load-bearing — builds fail on the runner without them. `macos-latest` still maps to macOS 15, so keep the explicit `macos-26` label.
