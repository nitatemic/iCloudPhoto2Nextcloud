//
//  SyncedAsset.swift
//  iCloudPhoto2Nextcloud
//

import Foundation
import SwiftData
import Photos

public enum SyncStatus: String, Codable {
    case pending = "pending"
    case syncing = "syncing"
    case synced = "synced"
    case failed = "failed"
}

@Model
public final class SyncedAsset {
    @Attribute(.unique) public var localIdentifier: String
    public var remotePath: String
    public var creationDate: Date?
    public var modificationDate: Date?
    public var mediaTypeRaw: Int
    public var mediaSubtypesRaw: UInt
    public var syncStatusRaw: String
    public var lastSyncedAt: Date?
    public var errorMessage: String?
    
    @Relationship(deleteRule: .cascade) public var resources: [SyncedResource]
    
    public var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .pending }
        set { syncStatusRaw = newValue.rawValue }
    }
    
    public var mediaType: PHAssetMediaType {
        PHAssetMediaType(rawValue: mediaTypeRaw) ?? .unknown
    }
    
    public var mediaSubtypes: PHAssetMediaSubtype {
        PHAssetMediaSubtype(rawValue: mediaSubtypesRaw)
    }
    
    public init(
        localIdentifier: String,
        remotePath: String,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        mediaTypeRaw: Int = 0,
        mediaSubtypesRaw: UInt = 0,
        syncStatus: SyncStatus = .pending,
        lastSyncedAt: Date? = nil,
        errorMessage: String? = nil,
        resources: [SyncedResource] = []
    ) {
        self.localIdentifier = localIdentifier
        self.remotePath = remotePath
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.mediaTypeRaw = mediaTypeRaw
        self.mediaSubtypesRaw = mediaSubtypesRaw
        self.syncStatusRaw = syncStatus.rawValue
        self.lastSyncedAt = lastSyncedAt
        self.errorMessage = errorMessage
        self.resources = resources
    }
}

@Model
public final class SyncedResource {
    public var resourceTypeRaw: Int
    public var originalFilename: String
    public var remoteFilename: String
    public var fileSize: Int64
    public var isSynced: Bool
    public var isAdjustment: Bool
    
    public var resourceType: PHAssetResourceType {
        PHAssetResourceType(rawValue: resourceTypeRaw) ?? .photo
    }
    
    public init(
        resourceTypeRaw: Int,
        originalFilename: String,
        remoteFilename: String,
        fileSize: Int64 = 0,
        isSynced: Bool = false,
        isAdjustment: Bool = false
    ) {
        self.resourceTypeRaw = resourceTypeRaw
        self.originalFilename = originalFilename
        self.remoteFilename = remoteFilename
        self.fileSize = fileSize
        self.isSynced = isSynced
        self.isAdjustment = isAdjustment
    }
}
