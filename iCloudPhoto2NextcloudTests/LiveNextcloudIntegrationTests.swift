//
//  LiveNextcloudIntegrationTests.swift
//  iCloudPhoto2NextcloudTests
//

import XCTest
@testable import iCloudPhoto2Nextcloud

final class LiveNextcloudIntegrationTests: XCTestCase {
    
    // Credentials fetched from environment or placeholder variables for safety
    var config: NextcloudConfig {
        let env = ProcessInfo.processInfo.environment
        let server = env["TEST_NEXTCLOUD_URL"] ?? "https://cloud.example.com"
        let user = env["TEST_NEXTCLOUD_USER"] ?? "dummy_user"
        let pass = env["TEST_NEXTCLOUD_PASS"] ?? "dummy_password"
        
        return NextcloudConfig(
            serverURL: server,
            username: user,
            appPassword: pass,
            targetFolder: "Photos/iCloudTest"
        )
    }
    
    func testLiveConnection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TEST_NEXTCLOUD_URL"] != nil else {
            // Skip live test if environment variables are not set
            print("Skipping live Nextcloud connection test (no TEST_NEXTCLOUD_URL set).")
            return
        }
        
        let service = NextcloudWebDAVService(config: config)
        do {
            let isConnected = try await service.testConnection()
            XCTAssertTrue(isConnected, "La connexion à Nextcloud devrait réussir.")
        } catch {
            XCTFail("Erreur de connexion Nextcloud: \(error.localizedDescription)")
        }
    }
    
    func testLiveWebDAVOperations() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TEST_NEXTCLOUD_URL"] != nil else {
            print("Skipping live WebDAV operations test (no TEST_NEXTCLOUD_URL set).")
            return
        }
        
        let service = NextcloudWebDAVService(config: config)
        let testFolderPath = "Photos/iCloudTest/IntegrationTest_\(UUID().uuidString)"
        let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_photo_\(UUID().uuidString).txt")
        let dummyContent = "Payload de test Nextcloud WebDAV le \(Date())"
        try dummyContent.write(to: tempFileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }
        
        let remoteFilePath = "\(testFolderPath)/test_photo.txt"
        
        do {
            try await service.createDirectory(path: testFolderPath)
            try await service.uploadFile(localFileURL: tempFileURL, remoteRelativePath: remoteFilePath)
            try await service.deleteFile(remoteRelativePath: remoteFilePath)
            try await service.deleteFile(remoteRelativePath: testFolderPath)
        } catch {
            XCTFail("Erreur lors des opérations WebDAV: \(error.localizedDescription)")
        }
    }
    
    /// Exerce le chemin d'upload chunké (> 10 Mo : MKCOL transfer, PUT de morceaux de 5 Mo, MOVE).
    func testLiveChunkedUpload() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TEST_NEXTCLOUD_URL"] != nil else {
            print("Skipping live chunked upload test (no TEST_NEXTCLOUD_URL set).")
            return
        }
        
        let service = NextcloudWebDAVService(config: config)
        let testFolderPath = "Photos/iCloudTest/ChunkedTest_\(UUID().uuidString)"
        let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_large_\(UUID().uuidString).bin")
        
        // 12 Mo > seuil de 10 Mo pour forcer le chunking v2 (morceaux de 5 Mo)
        let payload = Data(count: 12 * 1024 * 1024)
        try payload.write(to: tempFileURL)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }
        
        let remoteFilePath = "\(testFolderPath)/large_test.bin"
        
        do {
            try await service.uploadFile(localFileURL: tempFileURL, remoteRelativePath: remoteFilePath)
            try await service.deleteFile(remoteRelativePath: remoteFilePath)
            try await service.deleteFile(remoteRelativePath: testFolderPath)
        } catch {
            XCTFail("Erreur lors de l'upload chunké: \(error.localizedDescription)")
        }
    }
}
