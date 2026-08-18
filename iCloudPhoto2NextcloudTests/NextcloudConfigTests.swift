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
        #expect(config1.webDavBaseURL?.absoluteString == "https://nextcloud.example.com/remote.php/dav/files/user123/")
        
        // Case 2: URL without scheme (auto-prepends https://)
        let config2 = NextcloudConfig(
            serverURL: "nextcloud.example.com/",
            username: "admin",
            appPassword: "password"
        )
        #expect(config2.isValid == true) // Auto-prefixed with https://
        #expect(config2.webDavBaseURL?.absoluteString == "https://nextcloud.example.com/remote.php/dav/files/admin/")
        
        // Case 3: Empty fields validation
        let config3 = NextcloudConfig(
            serverURL: "",
            username: "user",
            appPassword: "pass"
        )
        #expect(config3.isValid == false)
        #expect(config3.webDavBaseURL == nil)
    }

    @Test("Test percent-encoding of special characters in username")
    func testUsernameEncoding() throws {
        let config = NextcloudConfig(
            serverURL: "https://nextcloud.example.com",
            username: "user name@exemple.fr",
            appPassword: "pass"
        )
        let url = try #require(config.webDavBaseURL)
        #expect(url.absoluteString == "https://nextcloud.example.com/remote.php/dav/files/user%20name@exemple.fr/")
    }
    
    @Test("Test verification settings defaults and persistence")
    func testVerificationSettings() throws {
        let defaults = UserDefaults.standard
        let autoVerifyKey = "nc_auto_verify"
        let intervalKey = "nc_verify_interval_days"
        let savedAuto = defaults.object(forKey: autoVerifyKey) as? Bool
        let savedInterval = defaults.object(forKey: intervalKey) as? Int
        
        let config = NextcloudConfig(
            serverURL: "https://nextcloud.example.com",
            username: "user",
            appPassword: "pass",
            autoVerifyEnabled: true,
            verifyIntervalDays: 30
        )
        config.saveToKeychain()
        defer {
            // Restaure l'état Utilisateur précédent pour ne pas polluer les autres tests
            if let savedAuto {
                defaults.set(savedAuto, forKey: autoVerifyKey)
            } else {
                defaults.removeObject(forKey: autoVerifyKey)
            }
            if let savedInterval {
                defaults.set(savedInterval, forKey: intervalKey)
            } else {
                defaults.removeObject(forKey: intervalKey)
            }
        }
        
        let loaded = NextcloudConfig.loadFromKeychain()
        #expect(loaded.autoVerifyEnabled == true)
        #expect(loaded.verifyIntervalDays == 30)
        
        // Valeurs par défaut d'un config fraîche
        let fresh = NextcloudConfig()
        #expect(fresh.autoVerifyEnabled == false)
        #expect(fresh.verifyIntervalDays == 7)
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
