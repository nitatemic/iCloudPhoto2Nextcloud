//
//  SwiftDataCatalogTests.swift
//  iCloudPhoto2NextcloudTests
//

import Testing
import Foundation
import SwiftData
@testable import iCloudPhoto2Nextcloud

@MainActor
struct SwiftDataCatalogTests {
    
    @Test("Test SwiftData SyncedAsset insertion and retrieval")
    func testSyncedAssetCatalog() throws {
        let schema = Schema([SyncedAsset.self, SyncedResource.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        
        let localID = "ASSET-12345/L0/001"
        let remotePath = "Photos/iCloud/2026/08"
        
        let asset = SyncedAsset(
            localIdentifier: localID,
            remotePath: remotePath,
            creationDate: Date(),
            mediaTypeRaw: 1, // Image
            syncStatus: .pending
        )
        
        let resource = SyncedResource(
            resourceTypeRaw: 1,
            originalFilename: "IMG_0001.HEIC",
            remoteFilename: "IMG_0001.HEIC",
            fileSize: 2048000,
            isSynced: false
        )
        
        asset.resources.append(resource)
        context.insert(asset)
        try context.save()
        
        // Fetch
        let descriptor = FetchDescriptor<SyncedAsset>(predicate: #Predicate { $0.localIdentifier == localID })
        let fetched = try context.fetch(descriptor)
        
        #expect(fetched.count == 1)
        #expect(fetched.first?.localIdentifier == localID)
        #expect(fetched.first?.syncStatus == .pending)
        #expect(fetched.first?.resources.count == 1)
        #expect(fetched.first?.resources.first?.originalFilename == "IMG_0001.HEIC")
    }
}
