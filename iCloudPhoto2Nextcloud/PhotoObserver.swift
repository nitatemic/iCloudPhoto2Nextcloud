//
//  PhotoObserver.swift
//  iCloudPhoto2Nextcloud
//

import Foundation
import Photos
import Combine

public struct ExtractedMediaResource: Sendable {
    public let resourceType: PHAssetResourceType
    public let originalFilename: String
    public let fileURL: URL
    public let fileSize: Int64
    public let isAdjustment: Bool
}

public struct PhotoChangeEvent: Sendable {
    public let insertedAssets: [PHAsset]
    public let updatedAssets: [PHAsset]
    public let deletedAssetIDs: [String]
}

@MainActor
public protocol PhotoObserverDelegate: AnyObject {
    func photoObserver(_ observer: PhotoObserver, didReceiveChangeEvent event: PhotoChangeEvent)
    func photoObserver(_ observer: PhotoObserver, didChangeAuthorizationStatus status: PHAuthorizationStatus)
}

/// PhotoKit Manager listening to real-time library changes via PHPhotoLibraryChangeObserver
/// and extracting raw original files, Live Photos (HEIC + MOV), and video files via PHAssetResourceManager.
public final class PhotoObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    public static let shared = PhotoObserver()
    
    public weak var delegate: PhotoObserverDelegate?
    
    private var fetchResult: PHFetchResult<PHAsset>?
    private let queue = DispatchQueue(label: "com.icloudphoto2nextcloud.photoobserver", qos: .userInitiated)
    
    private override init() {
        super.init()
    }
    
    // MARK: - PhotoKit Authorization & Subscription
    public func startObserving() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        Task { @MainActor in
            self.delegate?.photoObserver(self, didChangeAuthorizationStatus: status)
        }
        
        guard status == .authorized || status == .limited else {
            return
        }
        
        queue.async { [weak self] in
            guard let self = self else { return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            self.fetchResult = PHAsset.fetchAssets(with: options)
            PHPhotoLibrary.shared().register(self)
        }
    }
    
    public func stopObserving() {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
    
    public func requestAuthorization() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if status == .authorized || status == .limited {
            startObserving()
        }
        return status
    }

    // MARK: - PHPhotoLibraryChangeObserver
    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            guard let currentFetchResult = self.fetchResult else {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                self.fetchResult = PHAsset.fetchAssets(with: options)
                return
            }
            
            guard let changeDetails = changeInstance.changeDetails(for: currentFetchResult) else {
                return
            }
            
            self.fetchResult = changeDetails.fetchResultAfterChanges
            
            let inserted = changeDetails.insertedObjects
            let updated = changeDetails.changedObjects
            let deletedIDs = changeDetails.removedObjects.map { $0.localIdentifier }
            
            let event = PhotoChangeEvent(
                insertedAssets: inserted,
                updatedAssets: updated,
                deletedAssetIDs: deletedIDs
            )
            
            Task { @MainActor in
                self.delegate?.photoObserver(self, didReceiveChangeEvent: event)
            }
        }
    }
    
    // MARK: - Full Library Fetch (Manual Scan Trigger)
    public func fetchAllAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }
    
    // MARK: - Asset Resource Extraction (PHAssetResourceManager)
    /// Extracts all component files for a PHAsset:
    /// - Standard photos: Original file + modified/adjusted file if edited.
    /// - RAW & ProRAW: Original RAW resource + companion JPEG/HEIC.
    /// - Live Photos: Both original HEIC/JPG image AND paired MOV video component.
    /// - Videos: Uncompressed original video file.
    public func extractResources(for asset: PHAsset, scratchDirectory: URL) async throws -> [ExtractedMediaResource] {
        let assetResources = PHAssetResource.assetResources(for: asset)
        var extracted: [ExtractedMediaResource] = []
        
        let resourceManager = PHAssetResourceManager.default()
        
        for resource in assetResources {
            // Determine filename and extension
            let filename = resource.originalFilename
            let targetTempURL = scratchDirectory.appendingPathComponent(UUID().uuidString + "_" + filename)
            
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true // Allow fetching original from iCloud if not local
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                resourceManager.writeData(for: resource, toFile: targetTempURL, options: options) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            
            var fileSize: Int64 = 0
            if let attr = try? FileManager.default.attributesOfItem(atPath: targetTempURL.path) {
                fileSize = (attr[.size] as? NSNumber)?.int64Value ?? 0
            }
            
            let isAdjustment = (resource.type == .adjustmentData || resource.type == .fullSizePhoto || resource.type == .fullSizeVideo)
            
            extracted.append(
                ExtractedMediaResource(
                    resourceType: resource.type,
                    originalFilename: filename,
                    fileURL: targetTempURL,
                    fileSize: fileSize,
                    isAdjustment: isAdjustment
                )
            )
        }
        
        return extracted
    }
}
