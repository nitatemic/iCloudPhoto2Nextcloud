//
//  SyncEngineTests.swift
//  iCloudPhoto2NextcloudTests
//

import Testing
import Foundation
@testable import iCloudPhoto2Nextcloud

@MainActor
struct SyncEngineTests {
    
    @Test("Test SyncEngine logging and state management")
    func testSyncEngineLogRecording() throws {
        let engine = SyncEngine.shared
        let initialLogCount = engine.recentLogs.count
        
        engine.log("Test log entry message", level: .info)
        
        #expect(engine.recentLogs.count == initialLogCount + 1)
        #expect(engine.recentLogs.first?.message == "Test log entry message")
        #expect(engine.recentLogs.first?.level == .info)
    }
}
