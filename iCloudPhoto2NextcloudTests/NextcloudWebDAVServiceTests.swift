//
//  NextcloudWebDAVServiceTests.swift
//  iCloudPhoto2NextcloudTests
//

import Testing
import Foundation
@testable import iCloudPhoto2Nextcloud

struct NextcloudWebDAVServiceTests {
    
    @Test("Test WebDAV service initialization with invalid config")
    func testInvalidConfigError() async throws {
        let invalidConfig = NextcloudConfig(
            serverURL: "",
            username: "",
            appPassword: ""
        )
        let service = NextcloudWebDAVService(config: invalidConfig)
        
        await #expect(throws: WebDAVError.self) {
            _ = try await service.testConnection()
        }
    }
    
    @Test("Test WebDAV Error Descriptions")
    func testErrorDescriptions() throws {
        let httpError = WebDAVError.httpError(statusCode: 401, message: "Unauthorized")
        #expect(httpError.errorDescription?.contains("401") == true)
        
        let invalidConfigError = WebDAVError.invalidConfig
        #expect(invalidConfigError.errorDescription?.contains("manquante") == true)
    }
}
