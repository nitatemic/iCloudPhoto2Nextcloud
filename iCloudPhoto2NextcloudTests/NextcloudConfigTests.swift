//
//  NextcloudConfigTests.swift
//  iCloudPhoto2NextcloudTests
//

import Testing
import Foundation
@testable import iCloudPhoto2Nextcloud

struct NextcloudConfigTests {
    
    @Test("Test NextcloudConfig URL normalization & WebDAV URL building")
    func testWebDavBaseURL() throws {
        // Case 1: Standard URL
        let config1 = NextcloudConfig(
            serverURL: "https://nextcloud.example.com",
            username: "user123",
            appPassword: "secret-token"
        )
        #expect(config1.isValid == true)
        #expect(config1.webDavBaseURL?.absoluteString == "https://nextcloud.example.com/remote.php/dav/files/user123")
        
        // Case 2: URL without scheme
        let config2 = NextcloudConfig(
            serverURL: "nextcloud.example.com/",
            username: "admin",
            appPassword: "password"
        )
        #expect(config2.isValid == false) // Needs scheme or normalization
        #expect(config2.webDavBaseURL?.absoluteString == "https://nextcloud.example.com/remote.php/dav/files/admin")
        
        // Case 3: Empty fields validation
        let config3 = NextcloudConfig(
            serverURL: "",
            username: "user",
            appPassword: "pass"
        )
        #expect(config3.isValid == false)
        #expect(config3.webDavBaseURL == nil)
    }
    
    @Test("Test KeychainManager save, read, and delete")
    func testKeychainManager() throws {
        let testKey = "test_credentials_key_\(UUID().uuidString)"
        let testSecret = "my-secret-app-token-12345"
        
        // Save
        let saved = KeychainManager.shared.save(key: testKey, string: testSecret)
        #expect(saved == true)
        
        // Retrieve
        let retrieved = KeychainManager.shared.getString(key: testKey)
        #expect(retrieved == testSecret)
        
        // Delete
        KeychainManager.shared.delete(key: testKey)
        let afterDelete = KeychainManager.shared.getString(key: testKey)
        #expect(afterDelete == nil)
    }
}
