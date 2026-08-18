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
    
    @Test("Test PROPFIND multistatus XML parsing")
    func testParseMultistatusResponse() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
          <d:response>
            <d:href>/remote.php/dav/files/user/Photos/iCloud/2026/08/</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/user/Photos/iCloud/2026/08/IMG_1234.HEIC</d:href>
            <d:propstat>
              <d:prop>
                <d:getcontentlength>2048000</d:getcontentlength>
                <d:resourcetype/>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/user/Photos/iCloud/2026/08/IMG%201234.MOV</d:href>
            <d:propstat>
              <d:prop>
                <d:getcontentlength>123456789</d:getcontentlength>
                <d:resourcetype/>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/user/Photos/iCloud/2026/08/RAW_0001.DNG</d:href>
            <d:propstat>
              <d:prop>
                <d:getcontentlength>0</d:getcontentlength>
                <d:resourcetype/>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        
        let parsed = NextcloudWebDAVService.parseMultistatusResponse(Data(xml.utf8))
        
        // Le dossier (href avec "/" final) est ignoré, le nom avec espace est décodé
        #expect(parsed.count == 3)
        #expect(parsed.contains(RemoteFileInfo(filename: "IMG_1234.HEIC", fileSize: 2048000)))
        #expect(parsed.contains(RemoteFileInfo(filename: "IMG 1234.MOV", fileSize: 123456789)))
        #expect(parsed.contains(RemoteFileInfo(filename: "RAW_0001.DNG", fileSize: 0)))
    }
    
    @Test("Test PROPFIND parsing of empty and malformed responses")
    func testParseMultistatusEmpty() throws {
        #expect(NextcloudWebDAVService.parseMultistatusResponse(Data("".utf8)).isEmpty)
        #expect(NextcloudWebDAVService.parseMultistatusResponse(Data("<d:multistatus xmlns:d=\"DAV:\"/>".utf8)).isEmpty)
        #expect(NextcloudWebDAVService.parseMultistatusResponse(Data("not XML at all".utf8)).isEmpty)
    }
}
