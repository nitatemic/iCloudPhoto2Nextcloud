# Design Document: GitHub Actions macOS Build Workflow

## Overview
This specification details the setup of a GitHub Actions workflow (`.github/workflows/build-macos.yml`) for compiling the native macOS application `iCloudPhoto2Nextcloud`.
The workflow generates three build artifacts for maximum compatibility:
1. **Universal Binary** (`iCloudPhoto2Nextcloud-Universal.zip`): Includes both `x86_64` (Intel) and `arm64` (Apple Silicon) architectures in a single app bundle.
2. **Intel Binary** (`iCloudPhoto2Nextcloud-Intel-x86_64.zip`): Optimized for Intel-based Macs.
3. **Apple Silicon Binary** (`iCloudPhoto2Nextcloud-AppleSilicon-arm64.zip`): Optimized for M1/M2/M3/M4 Apple Silicon Macs.

---

## Workflow Triggers
- `push` on the `main` branch.
- `workflow_dispatch` (manual trigger from GitHub UI).

---

## Runner & Environment
- **Runner**: `macos-14` (Apple Silicon host with Xcode 15+ / macOS 14 SDK support).
- **Tooling**: `xcodebuild`, `ditto` / `zip`, `actions/checkout@v4`, `actions/upload-artifact@v4`.

---

## Build Architecture & Steps

### 1. Repository Checkout
Uses `actions/checkout@v4`.

### 2. Xcode Setup & Environment Check
Validates Xcode installation version and sets build output paths to a predictable local workspace directory (`./build`).

### 3. Compilation Matrix / Build Pipeline
- **Universal Build**:
  - `xcodebuild -scheme iCloudPhoto2Nextcloud -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO build`
  - Compress output `.app` bundle to `iCloudPhoto2Nextcloud-Universal.zip`.
- **Intel (x86_64) Build**:
  - `xcodebuild -scheme iCloudPhoto2Nextcloud -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData ARCHS="x86_64" ONLY_ACTIVE_ARCH=NO build`
  - Compress output `.app` bundle to `iCloudPhoto2Nextcloud-Intel-x86_64.zip`.
- **Apple Silicon (arm64) Build**:
  - `xcodebuild -scheme iCloudPhoto2Nextcloud -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData ARCHS="arm64" ONLY_ACTIVE_ARCH=NO build`
  - Compress output `.app` bundle to `iCloudPhoto2Nextcloud-AppleSilicon-arm64.zip`.

### 4. Artifact Storage
Uploads all 3 compressed zip files as a GitHub Actions artifact named `macOS-App-Builds` using `actions/upload-artifact@v4`.

---

## Verification Plan
1. Validate syntax of `.github/workflows/build-macos.yml`.
2. Perform local verification of the build commands with `xcodebuild` targeting both architectures and `lipo` inspection of generated binary slices.
