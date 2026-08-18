//
//  AppUpdaterTests.swift
//  iCloudPhoto2NextcloudTests
//

import Testing
import Foundation
@testable import iCloudPhoto2Nextcloud

struct AppUpdaterTests {
    
    private func asset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(name: name, browserDownloadURL: "https://github.com/nitatemic/iCloudPhoto2Nextcloud/releases/download/ci-test/\(name)")
    }
    
    @Test("Asset selection matches the host architecture")
    func testSelectAsset() {
        let assets = [
            asset("iCloudPhoto2Nextcloud-Universal.zip"),
            asset("iCloudPhoto2Nextcloud-macOS-Intel-x86_64.zip"),
            asset("iCloudPhoto2Nextcloud-macOS-AppleSilicon-arm64.zip")
        ]
        
        #expect(AppUpdater.selectAsset(for: "arm64", assets: assets)?.name.contains("AppleSilicon") == true)
        #expect(AppUpdater.selectAsset(for: "x86_64", assets: assets)?.name.contains("Intel") == true)
        #expect(AppUpdater.selectAsset(for: "unknown", assets: assets)?.name.contains("Universal") == true)
    }
    
    @Test("Asset selection falls back to the universal build only")
    func testSelectAssetFallback() {
        // Un binaire Apple Silicon ne tourne pas sur Intel : aucun repli hasardeux.
        let appleSiliconOnly = [asset("iCloudPhoto2Nextcloud-macOS-AppleSilicon-arm64.zip")]
        #expect(AppUpdater.selectAsset(for: "x86_64", assets: appleSiliconOnly) == nil)
        #expect(AppUpdater.selectAsset(for: "arm64", assets: []) == nil)
    }
    
    @Test("SHA-256 checksum is extracted from the release body")
    func testSha256Extraction() {
        let body = """
        Build automatique du commit `abc123` — binaires **non signés**.

        | Fichier | Architecture | Empreinte SHA-256 |
        |---|---|---|
        | iCloudPhoto2Nextcloud-Universal.zip | Intel + Apple Silicon | 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 |
        | iCloudPhoto2Nextcloud-macOS-AppleSilicon-arm64.zip | Apple Silicon | e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 |
        """
        
        #expect(AppUpdater.sha256ForAsset(named: "iCloudPhoto2Nextcloud-Universal.zip", in: body) == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
        #expect(AppUpdater.sha256ForAsset(named: "iCloudPhoto2Nextcloud-macOS-AppleSilicon-arm64.zip", in: body) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
    
    @Test("Missing checksum returns nil")
    func testSha256Missing() {
        let body = "| iCloudPhoto2Nextcloud-Universal.zip | Intel + Apple Silicon | 123 |"
        #expect(AppUpdater.sha256ForAsset(named: "iCloudPhoto2Nextcloud-Universal.zip", in: body) == nil)
        #expect(AppUpdater.sha256ForAsset(named: "inexistant.zip", in: body) == nil)
    }
    
    @Test("ReleaseInfo decodes from the GitHub API payload")
    func testReleaseDecoding() throws {
        let json = """
        {
          "tag_name" : "ci-abc123",
          "body" : "| iCloudPhoto2Nextcloud-Universal.zip | Intel + Apple Silicon | 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 |",
          "assets" : [
            {
              "name" : "iCloudPhoto2Nextcloud-Universal.zip",
              "browser_download_url" : "https://github.com/nitatemic/iCloudPhoto2Nextcloud/releases/download/ci-abc123/iCloudPhoto2Nextcloud-Universal.zip"
            }
          ]
        }
        """
        let release = try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
        #expect(release.tagName == "ci-abc123")
        #expect(release.assets.count == 1)
        #expect(release.assets.first?.name == "iCloudPhoto2Nextcloud-Universal.zip")
        #expect(release.assets.first?.browserDownloadURL.contains("download/ci-abc123") == true)
    }
    
    @Test("SHA-256 of known data")
    func testSha256Computation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha_test_\(UUID().uuidString).bin")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let hash = try AppUpdater.sha256(of: url)
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    
    @Test("Update errors are localized")
    func testUpdateErrorDescriptions() {
        #expect(UpdateError.checksumMismatch.localizedDescription.contains("SHA-256"))
        #expect(UpdateError.missingChecksum.localizedDescription.contains("SHA-256"))
        #expect(UpdateError.noAssetForArchitecture("arm64").localizedDescription.contains("arm64"))
        #expect(UpdateError.destinationNotWritable("/Applications").localizedDescription.contains("/Applications"))
    }
}