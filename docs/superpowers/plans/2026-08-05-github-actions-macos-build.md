# GitHub Actions macOS Build Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a GitHub Actions workflow (`.github/workflows/build-macos.yml`) that compiles the `iCloudPhoto2Nextcloud` macOS app for Universal Binary (Intel x86_64 + Apple Silicon arm64), Intel x86_64, and Apple Silicon arm64, compressing each variant into `.zip` archives and uploading them as GitHub Actions release artifacts.

**Architecture:** A single GitHub Actions workflow running on `macos-14` (Apple Silicon runner) triggered on pushes to `main` and `workflow_dispatch`. It executes `xcodebuild` three times with appropriate `ARCHS` flags, archives the resulting `.app` bundles with `ditto`, and publishes the artifacts using `actions/upload-artifact@v4`.

**Tech Stack:** GitHub Actions, Xcode (`xcodebuild`), macOS 14 SDK, Swift, `ditto`.

## Global Constraints
- Target macOS deployment version: 14.0.
- Target Xcode scheme: `iCloudPhoto2Nextcloud`.
- Build configurations: `Release`.
- Output zip files:
  - `iCloudPhoto2Nextcloud-Universal.zip`
  - `iCloudPhoto2Nextcloud-macOS-Intel-x86_64.zip`
  - `iCloudPhoto2Nextcloud-macOS-AppleSilicon-arm64.zip`

---

### Task 1: Create GitHub Actions Workflow File

**Files:**
- Create: `.github/workflows/build-macos.yml`

**Interfaces:**
- Consumes: Xcode scheme `iCloudPhoto2Nextcloud` in `iCloudPhoto2Nextcloud.xcodeproj`.
- Produces: GitHub Actions workflow file `.github/workflows/build-macos.yml`.

- [ ] **Step 1: Write `.github/workflows/build-macos.yml`**

Create `.github/workflows/build-macos.yml` with the following content:

```yaml
name: Build macOS App

on:
  push:
    branches:
      - main
  workflow_dispatch:

jobs:
  build:
    name: Build macOS Binaries (Universal, Intel, Apple Silicon)
    runs-on: macos-14

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.4.app || sudo xcode-select -s /Applications/Xcode.app

      - name: Build Universal Binary (x86_64 + arm64)
        run: |
          xcodebuild -scheme iCloudPhoto2Nextcloud \
            -configuration Release \
            -destination 'generic/platform=macOS' \
            -derivedDataPath build/DerivedDataUniversal \
            ARCHS="x86_64 arm64" \
            ONLY_ACTIVE_ARCH=NO \
            clean build
          
          mkdir -p build/artifacts
          ditto -c -k --sequesterRsrc \
            build/DerivedDataUniversal/Build/Products/Release/iCloudPhoto2Nextcloud.app \
            build/artifacts/iCloudPhoto2Nextcloud-Universal.zip

      - name: Build Intel Binary (x86_64)
        run: |
          xcodebuild -scheme iCloudPhoto2Nextcloud \
            -configuration Release \
            -destination 'generic/platform=macOS' \
            -derivedDataPath build/DerivedDataIntel \
            ARCHS="x86_64" \
            ONLY_ACTIVE_ARCH=NO \
            clean build

          ditto -c -k --sequesterRsrc \
            build/DerivedDataIntel/Build/Products/Release/iCloudPhoto2Nextcloud.app \
            build/artifacts/iCloudPhoto2Nextcloud-macOS-Intel-x86_64.zip

      - name: Build Apple Silicon Binary (arm64)
        run: |
          xcodebuild -scheme iCloudPhoto2Nextcloud \
            -configuration Release \
            -destination 'generic/platform=macOS' \
            -derivedDataPath build/DerivedDataARM64 \
            ARCHS="arm64" \
            ONLY_ACTIVE_ARCH=NO \
            clean build

          ditto -c -k --sequesterRsrc \
            build/DerivedDataARM64/Build/Products/Release/iCloudPhoto2Nextcloud.app \
            build/artifacts/iCloudPhoto2Nextcloud-macOS-AppleSilicon-arm64.zip

      - name: Upload Build Artifacts
        uses: actions/upload-artifact@v4
        with:
          name: macOS-App-Builds
          path: build/artifacts/*.zip
          if-no-files-found: error
```

- [ ] **Step 2: Verify YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-macos.yml'))"`
Expected: Clean exit code 0.

- [ ] **Step 3: Commit workflow file**

```bash
git add .github/workflows/build-macos.yml
git commit -m "ci: add GitHub Actions workflow for Universal, Intel, and ARM64 macOS builds"
```

---

### Task 2: Verify Build Commands Locally & Validate Plan

**Files:**
- Test local build output paths & binary architecture validation using `lipo`.

- [ ] **Step 1: Test xcodebuild and lipo verification locally**

Run:
```bash
xcodebuild -scheme iCloudPhoto2Nextcloud -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedDataUniversal ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO build
lipo -info build/DerivedDataUniversal/Build/Products/Release/iCloudPhoto2Nextcloud.app/Contents/MacOS/iCloudPhoto2Nextcloud
```
Expected output: `Architectures in the fat file: build/DerivedDataUniversal/Build/Products/Release/iCloudPhoto2Nextcloud.app/Contents/MacOS/iCloudPhoto2Nextcloud are: x86_64 arm64`

- [ ] **Step 2: Clean up local build directory**

Run: `rm -rf build`
Expected: Clean exit code 0.

- [ ] **Step 3: Commit plan and finish**

```bash
git add docs/superpowers/plans/2026-08-05-github-actions-macos-build.md
git commit -m "docs: add implementation plan for GitHub Actions workflow"
```
