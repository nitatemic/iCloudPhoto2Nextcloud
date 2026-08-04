//
//  SyncEngine.swift
//  iCloudPhoto2Nextcloud
//

import Foundation
import SwiftData
import Photos
import Combine
import SwiftUI

public enum EngineState: Equatable, Sendable {
    case idle
    case syncing(progress: Double, message: String)
    case paused(progress: Double, message: String)
    case unauthorized
    case error(String)
}

@MainActor
@Observable
public final class SyncEngine: PhotoObserverDelegate {
    public static let shared = SyncEngine()
    
    public var state: EngineState = .idle
    public var totalAssets: Int = 0
    public var syncedAssetsCount: Int = 0
    public var pendingAssetsCount: Int = 0
    public var lastSyncDate: Date?
    public var recentLogs: [SyncLogEntry] = []
    public var isPaused: Bool = false
    
    public var config: NextcloudConfig {
        didSet {
            Task {
                await webDavService.updateConfig(config)
            }
        }
    }
    
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let webDavService: NextcloudWebDAVService
    private let photoObserver: PhotoObserver
    
    private var isSyncingInProcess = false
    private var syncTask: Task<Void, Never>?
    
    private init() {
        let loadedConfig = NextcloudConfig.loadFromKeychain()
        self.config = loadedConfig
        self.webDavService = NextcloudWebDAVService(config: loadedConfig)
        self.photoObserver = PhotoObserver.shared
        
        do {
            let schema = Schema([SyncedAsset.self, SyncedResource.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: schema, configurations: [config])
            self.modelContainer = container
            self.modelContext = ModelContext(container)
        } catch {
            fatalError("Erreur d'initialisation de SwiftData: \(error.localizedDescription)")
        }
        
        self.photoObserver.delegate = self
        updateStatsFromDatabase()
    }
    
    // MARK: - App Lifecycle Start
    public func startEngine() {
        log("Démarrage du moteur de synchronisation...", level: .info)
        photoObserver.startObserving()
        
        Task {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined {
                _ = await photoObserver.requestAuthorization()
            } else if status == .denied || status == .restricted {
                self.state = .unauthorized
                log("Accès aux photos refusé. Veuillez accorder la permission dans Réglages Système.", level: .error)
            } else {
                performFullScan()
            }
        }
    }
    
    public func log(_ message: String, level: SyncLogEntry.LogLevel = .info) {
        let entry = SyncLogEntry(message: message, level: level)
        recentLogs.insert(entry, at: 0)
        if recentLogs.count > 200 {
            recentLogs.removeLast()
        }
    }
    
    // MARK: - Pause / Resume Controls
    public func pauseSync() {
        guard !isPaused else { return }
        isPaused = true
        if case .syncing(let progress, _) = state {
            state = .paused(progress: progress, message: "Synchronisation en pause")
        } else {
            state = .paused(progress: 0.0, message: "Synchronisation en pause")
        }
        log("Mise en pause de la synchronisation.", level: .warning)
    }
    
    public func resumeSync() {
        guard isPaused else { return }
        isPaused = false
        log("Reprise de la synchronisation.", level: .info)
    }
    
    public func togglePause() {
        if isPaused {
            resumeSync()
        } else {
            pauseSync()
        }
    }
    
    // MARK: - PhotoObserverDelegate
    public func photoObserver(_ observer: PhotoObserver, didChangeAuthorizationStatus status: PHAuthorizationStatus) {
        if status == .authorized || status == .limited {
            log("Accès aux photos autorisé (\(status == .limited ? "limité" : "complet")).", level: .info)
            performFullScan()
        } else if status == .denied || status == .restricted {
            self.state = .unauthorized
            log("Accès aux photos révoqué.", level: .error)
        }
    }
    
    public func photoObserver(_ observer: PhotoObserver, didReceiveChangeEvent event: PhotoChangeEvent) {
        log("Changement PhotoKit détecté: +\(event.insertedAssets.count), ~\(event.updatedAssets.count), -\(event.deletedAssetIDs.count)", level: .info)
        
        Task {
            if !event.deletedAssetIDs.isEmpty {
                await processDeletions(assetIDs: event.deletedAssetIDs)
            }
            
            let assetsToProcess = event.insertedAssets + event.updatedAssets
            if !assetsToProcess.isEmpty {
                await enqueueAssetsForSync(assetsToProcess)
            }
        }
    }
    
    // MARK: - Database Stats Update
    public func updateStatsFromDatabase() {
        do {
            let descriptor = FetchDescriptor<SyncedAsset>()
            let all = try modelContext.fetch(descriptor)
            self.totalAssets = all.count
            self.syncedAssetsCount = all.filter { $0.syncStatus == .synced }.count
            self.pendingAssetsCount = all.filter { $0.syncStatus == .pending || $0.syncStatus == .syncing || $0.syncStatus == .failed }.count
        } catch {
            log("Erreur lors de la lecture de la base locale: \(error.localizedDescription)", level: .error)
        }
    }
    
    // MARK: - Full Library Scan
    public func performFullScan() {
        guard !isSyncingInProcess else { return }
        
        syncTask = Task {
            log("Lancement du scan complet de la photothèque...", level: .info)
            let assets = photoObserver.fetchAllAssets()
            log("\(assets.count) éléments trouvés dans la photothèque.", level: .info)
            
            await enqueueAssetsForSync(assets)
        }
    }
    
    // MARK: - 2-Phase Pre-Scan & Batch Sync Processing
    private func enqueueAssetsForSync(_ assets: [PHAsset]) async {
        guard config.isValid else {
            self.state = .error("Configuration Nextcloud incomplète.")
            log("Configuration Nextcloud manquante ou invalide.", level: .warning)
            return
        }
        
        guard !assets.isEmpty else {
            updateStatsFromDatabase()
            if self.pendingAssetsCount == 0 {
                self.state = .idle
            }
            return
        }
        
        isSyncingInProcess = true
        self.state = .syncing(progress: 0.0, message: "Indexation de la photothèque...")
        
        // ----------------------------------------------------
        // PHASE 1: Indexation & Décompte total des éléments à envoyer
        // ----------------------------------------------------
        var pendingAssetPairs: [(asset: PHAsset, syncedRecord: SyncedAsset)] = []
        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "yyyy"
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MM"
        
        for (index, asset) in assets.enumerated() {
            if Task.isCancelled { break }
            
            // Progress update for indexation phase
            if index % 50 == 0 || index == assets.count - 1 {
                let indexProgress = Double(index + 1) / Double(assets.count)
                self.state = .syncing(progress: indexProgress * 0.1, message: "Analyse \(index + 1) / \(assets.count)...")
            }
            
            let localID = asset.localIdentifier
            let descriptor = FetchDescriptor<SyncedAsset>(predicate: #Predicate { $0.localIdentifier == localID })
            let existing = try? modelContext.fetch(descriptor).first
            
            let targetAsset: SyncedAsset
            if let found = existing {
                if found.syncStatus == .synced {
                    // Check if modification date has changed
                    if let modDate = asset.modificationDate, let lastMod = found.modificationDate, modDate <= lastMod {
                        continue // Already up to date, skip
                    }
                }
                targetAsset = found
            } else {
                let date = asset.creationDate ?? Date()
                let year = yearFormatter.string(from: date)
                let month = monthFormatter.string(from: date)
                let remoteDirectoryPath = "\(config.targetFolder)/\(year)/\(month)"
                
                targetAsset = SyncedAsset(
                    localIdentifier: localID,
                    remotePath: remoteDirectoryPath,
                    creationDate: asset.creationDate,
                    modificationDate: asset.modificationDate,
                    mediaTypeRaw: asset.mediaType.rawValue,
                    mediaSubtypesRaw: asset.mediaSubtypes.rawValue,
                    syncStatus: .pending
                )
                modelContext.insert(targetAsset)
            }
            
            pendingAssetPairs.append((asset, targetAsset))
        }
        
        try? modelContext.save()
        updateStatsFromDatabase()
        
        let totalPendingToUpload = pendingAssetPairs.count
        log("\(totalPendingToUpload) élément(s) en attente d'envoi vers Nextcloud.", level: .info)
        
        if totalPendingToUpload == 0 {
            isSyncingInProcess = false
            self.state = .idle
            log("Tous les éléments sont déjà à jour sur Nextcloud.", level: .success)
            return
        }
        
        // ----------------------------------------------------
        // PHASE 2: Transfert vers Nextcloud avec progression réelle (X / Total)
        // ----------------------------------------------------
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SyncScratch_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        for (index, pair) in pendingAssetPairs.enumerated() {
            if Task.isCancelled { break }
            
            // Check Pause state loop
            while isPaused {
                let currentProgress = Double(index) / Double(totalPendingToUpload)
                self.state = .paused(progress: currentProgress, message: "En pause (\(index)/\(totalPendingToUpload))")
                try? await Task.sleep(for: .seconds(1))
            }
            
            let progress = Double(index) / Double(totalPendingToUpload)
            self.state = .syncing(progress: progress, message: "Envoi \(index + 1) / \(totalPendingToUpload)")
            
            await syncSingleAsset(pair.asset, targetAsset: pair.syncedRecord, scratchDirectory: tempDir)
            
            updateStatsFromDatabase()
        }
        
        isSyncingInProcess = false
        self.lastSyncDate = Date()
        updateStatsFromDatabase()
        self.state = .idle
        log("Synchronisation de \(totalPendingToUpload) élément(s) terminée avec succès.", level: .success)
    }
    
    // MARK: - Sync Single Asset (Mac -> Nextcloud)
    private func syncSingleAsset(_ asset: PHAsset, targetAsset: SyncedAsset, scratchDirectory: URL) async {
        targetAsset.syncStatus = .syncing
        try? modelContext.save()
        
        do {
            let resources = try await photoObserver.extractResources(for: asset, scratchDirectory: scratchDirectory)
            
            for resource in resources {
                let remoteFilePath = "\(targetAsset.remotePath)/\(resource.originalFilename)"
                
                log("Upload de \(resource.originalFilename) (\(ByteCountFormatter.string(fromByteCount: resource.fileSize, countStyle: .file)))...", level: .info)
                
                try await webDavService.uploadFile(localFileURL: resource.fileURL, remoteRelativePath: remoteFilePath) { subProgress in
                    // Sub progress
                }
                
                try? FileManager.default.removeItem(at: resource.fileURL)
                
                let syncedRes = SyncedResource(
                    resourceTypeRaw: resource.resourceType.rawValue,
                    originalFilename: resource.originalFilename,
                    remoteFilename: resource.originalFilename,
                    fileSize: resource.fileSize,
                    isSynced: true,
                    isAdjustment: resource.isAdjustment
                )
                targetAsset.resources.append(syncedRes)
            }
            
            targetAsset.syncStatus = .synced
            targetAsset.lastSyncedAt = Date()
            targetAsset.modificationDate = asset.modificationDate
            targetAsset.errorMessage = nil
            try? modelContext.save()
            
            log("Synchronisé: \(resourceFilenameSummary(targetAsset))", level: .success)
        } catch {
            targetAsset.syncStatus = .failed
            targetAsset.errorMessage = error.localizedDescription
            try? modelContext.save()
            log("Erreur sync \(asset.localIdentifier): \(error.localizedDescription)", level: .error)
        }
    }
    
    private func resourceFilenameSummary(_ targetAsset: SyncedAsset) -> String {
        let names = targetAsset.resources.map { $0.originalFilename }.joined(separator: ", ")
        return names.isEmpty ? targetAsset.localIdentifier : names
    }
    
    // MARK: - Process Deletions (Mirror: Local Delete -> Remote WebDAV DELETE)
    private func processDeletions(assetIDs: [String]) async {
        guard config.deleteRemoteOnLocalDelete else {
            log("Suppression distante ignorée (Option désactivée dans les réglages).", level: .info)
            return
        }
        
        for localID in assetIDs {
            let descriptor = FetchDescriptor<SyncedAsset>(predicate: #Predicate { $0.localIdentifier == localID })
            guard let found = try? modelContext.fetch(descriptor).first else { continue }
            
            log("Suppression distante Nextcloud pour asset supprimé: \(localID)", level: .info)
            
            for resource in found.resources {
                let remoteFilePath = "\(found.remotePath)/\(resource.remoteFilename)"
                do {
                    try await webDavService.deleteFile(remoteRelativePath: remoteFilePath)
                    log("Fichier distant supprimé: \(remoteFilePath)", level: .success)
                } catch {
                    log("Erreur lors de la suppression de \(remoteFilePath): \(error.localizedDescription)", level: .error)
                }
            }
            
            modelContext.delete(found)
            try? modelContext.save()
        }
        
        updateStatsFromDatabase()
    }
}
