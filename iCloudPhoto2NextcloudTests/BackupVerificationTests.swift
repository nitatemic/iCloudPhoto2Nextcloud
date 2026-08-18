//
//  BackupVerificationTests.swift
//  iCloudPhoto2NextcloudTests
//

import Testing
import Foundation
@testable import iCloudPhoto2Nextcloud

struct BackupVerificationTests {
    
    private func asset(_ localID: String, folder: String, resources: [(String, Int64)]) -> SyncedAssetInfo {
        SyncedAssetInfo(
            localIdentifier: localID,
            remotePath: folder,
            resources: resources.map { SyncedResourceInfo(remoteFilename: $0.0, fileSize: $0.1) }
        )
    }
    
    @Test("Everything present and matching sizes is reported intact")
    func testIntactBackup() {
        let assets = [
            asset("A1", folder: "Photos/iCloud/2026/08", resources: [("IMG_0001.HEIC", 100), ("IMG_0001.MOV", 200)]),
            asset("A2", folder: "Photos/iCloud/2026/09", resources: [("IMG_0002.HEIC", 50)])
        ]
        let server = [
            "Photos/iCloud/2026/08": [
                RemoteFileInfo(filename: "IMG_0001.HEIC", fileSize: 100),
                RemoteFileInfo(filename: "IMG_0001.MOV", fileSize: 200)
            ],
            "Photos/iCloud/2026/09": [
                RemoteFileInfo(filename: "IMG_0002.HEIC", fileSize: 50)
            ]
        ]
        
        let report = BackupVerifier.evaluateVerification(assets: assets, remoteFilesByFolder: server)
        
        #expect(report.damagedLocalIDs.isEmpty)
        #expect(report.missingFiles.isEmpty)
        #expect(report.sizeMismatches.isEmpty)
        #expect(report.orphanFiles.isEmpty)
        #expect(report.checkedResourceCount == 3)
        #expect(report.checkedFolderCount == 2)
    }
    
    @Test("Missing remote file marks the asset as damaged")
    func testMissingFile() {
        let assets = [asset("A1", folder: "Photos/iCloud/2026/08", resources: [("IMG_0001.HEIC", 100), ("IMG_0001.MOV", 200)])]
        let server = ["Photos/iCloud/2026/08": [RemoteFileInfo(filename: "IMG_0001.HEIC", fileSize: 100)]]
        
        let report = BackupVerifier.evaluateVerification(assets: assets, remoteFilesByFolder: server)
        
        #expect(report.damagedLocalIDs == ["A1"])
        #expect(report.missingFiles == ["Photos/iCloud/2026/08/IMG_0001.MOV"])
    }
    
    @Test("Size mismatch is reported as damage even when file exists")
    func testSizeMismatch() {
        let assets = [asset("A1", folder: "Photos/iCloud/2026/08", resources: [("IMG_0001.HEIC", 100)])]
        let server = ["Photos/iCloud/2026/08": [RemoteFileInfo(filename: "IMG_0001.HEIC", fileSize: 99)]]
        
        let report = BackupVerifier.evaluateVerification(assets: assets, remoteFilesByFolder: server)
        
        #expect(report.damagedLocalIDs == ["A1"])
        #expect(report.missingFiles.isEmpty)
        #expect(report.sizeMismatches.count == 1)
        #expect(report.sizeMismatches.first?.expectedSize == 100)
        #expect(report.sizeMismatches.first?.foundSize == 99)
    }
    
    @Test("Missing folder means every expected file is missing")
    func testMissingFolder() {
        let assets = [asset("A1", folder: "Photos/iCloud/2026/08", resources: [("IMG_0001.HEIC", 100)])]
        
        let report = BackupVerifier.evaluateVerification(assets: assets, remoteFilesByFolder: [:])
        
        #expect(report.damagedLocalIDs == ["A1"])
        #expect(report.checkedFolderCount == 1)
    }
    
    @Test("Size unknown on server is accepted (size check skipped)")
    func testUnknownServerSize() {
        let assets = [asset("A1", folder: "Photos/iCloud/2026/08", resources: [("IMG_0001.HEIC", 100)])]
        let server = ["Photos/iCloud/2026/08": [RemoteFileInfo(filename: "IMG_0001.HEIC", fileSize: nil)]]
        
        let report = BackupVerifier.evaluateVerification(assets: assets, remoteFilesByFolder: server)
        
        #expect(report.damagedLocalIDs.isEmpty)
    }
    
    @Test("Orphan files on server are reported but never damage assets")
    func testOrphanFiles() {
        let assets = [asset("A1", folder: "Photos/iCloud/2026/08", resources: [("IMG_0001.HEIC", 100)])]
        let server = ["Photos/iCloud/2026/08": [RemoteFileInfo(filename: "IMG_0001.HEIC", fileSize: 100), RemoteFileInfo(filename: "mystery.bin", fileSize: 1)]]
        
        let report = BackupVerifier.evaluateVerification(assets: assets, remoteFilesByFolder: server)
        
        #expect(report.damagedLocalIDs.isEmpty)
        #expect(report.orphanFiles == ["Photos/iCloud/2026/08/mystery.bin"])
    }
}