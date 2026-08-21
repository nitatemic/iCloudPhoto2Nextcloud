//
//  NextcloudLoginFlowTests.swift
//  iCloudPhoto2NextcloudTests
//

import Testing
import Foundation
@testable import iCloudPhoto2Nextcloud

struct NextcloudLoginFlowTests {
    
    @Test("Server URL normalization adds https and strips trailing slashes")
    func testNormalizedBaseURL() {
        #expect(NextcloudLoginFlow.normalizedBaseURL(from: "cloud.example.com")?.absoluteString == "https://cloud.example.com")
        #expect(NextcloudLoginFlow.normalizedBaseURL(from: "  https://cloud.example.com/  ")?.absoluteString == "https://cloud.example.com")
        #expect(NextcloudLoginFlow.normalizedBaseURL(from: "http://cloud.example.com/")?.absoluteString == "http://cloud.example.com")
        #expect(NextcloudLoginFlow.normalizedBaseURL(from: "https://host.example.com/nextcloud/")?.absoluteString == "https://host.example.com/nextcloud")
        #expect(NextcloudLoginFlow.normalizedBaseURL(from: "   ") == nil)
        #expect(NextcloudLoginFlow.normalizedBaseURL(from: "not a url") == nil)
    }
    
    @Test("Start response decoding exposes poll endpoint, token and login URL")
    func testDecodeStartResponse() throws {
        let json = """
        {
            "poll": {
                "token": "abc123token",
                "endpoint": "https://cloud.example.com/index.php/login/v2/poll"
            },
            "login": "https://cloud.example.com/login/flow?user=alice"
        }
        """.data(using: .utf8)!
        
        let session = try NextcloudLoginFlow.decodeStartResponse(json)
        #expect(session.pollToken == "abc123token")
        #expect(session.pollEndpoint.absoluteString == "https://cloud.example.com/index.php/login/v2/poll")
        #expect(session.loginURL.absoluteString == "https://cloud.example.com/login/flow?user=alice")
        #expect(session.isV2 == true)
    }
    
    @Test("Poll result decoding exposes server, login name and app password")
    func testDecodePollResult() throws {
        let json = """
        {
            "server": "https://cloud.example.com",
            "loginName": "alice",
            "appPassword": "abcd-wxyz-1234"
        }
        """.data(using: .utf8)!
        
        let credentials = try NextcloudLoginFlow.decodePollResult(json)
        #expect(credentials.serverURL == "https://cloud.example.com")
        #expect(credentials.loginName == "alice")
        #expect(credentials.appPassword == "abcd-wxyz-1234")
    }
    
    @Test("Malformed responses raise invalid response errors")
    func testDecodeInvalidResponses() {
        let broken = "not json".data(using: .utf8)!
        #expect(throws: LoginFlowError.invalidResponse) {
            _ = try NextcloudLoginFlow.decodeStartResponse(broken)
        }
        
        let missingKeys = """
        { "server": "https://cloud.example.com" }
        """.data(using: .utf8)!
        #expect(throws: LoginFlowError.invalidResponse) {
            _ = try NextcloudLoginFlow.decodePollResult(missingKeys)
        }
    }
    
    @Test("Login flow errors expose localized descriptions")
    func testErrorDescriptions() {
        #expect(LoginFlowError.invalidServerURL.localizedDescription.contains("URL"))
        #expect(LoginFlowError.browserFailed.localizedDescription.contains("navigateur"))
        #expect(LoginFlowError.declined.localizedDescription.contains("refusée"))
        #expect(LoginFlowError.timedOut.localizedDescription.contains("dépassé"))
        #expect(LoginFlowError.httpError(500).localizedDescription.contains("500"))
        #expect(LoginFlowError.networkError("timeout").localizedDescription.contains("timeout"))
    }
}