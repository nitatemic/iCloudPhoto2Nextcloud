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
    /// Vrai si des changements sont survenus pendant un cycle de sync : un scan de suivi sera lancé en fin de cycle.
    private var needsFollowUpScan = false
    /// Suppressions locales reçues pendant un cycle de sync, traitées en fin de cycle
    /// (évite de supprimer un modèle SwiftData encore référencé par la boucle d'upload en cours).
    private var pendingDeletionIDs: [String] = []
    /// Tâche de nouvel essai automatique après un cycle avec échecs.
    private var retryTask: Task<Void, Never>?
    /// Nombre de cycles consécutifs avec au moins un échec (plafonne les essais automatiques).
    private var consecutiveFailedRuns = 0
    private let maxConsecutiveFailedRuns = 3
    /// Nombre d'uploads simultanés en phase 2 (accélère les lots de petits fichiers).
    private let maxConcurrentUploads = 4

    private init() {
        let loadedConfig = NextcloudConfig.loadFromKeychain()
        self.config = loadedConfig
        self.webDavService = NextcloudWebDAVService(config: loadedConfig)
        self.photoObserver = PhotoObserver.shared

        let schema = Schema([SyncedAsset.self, SyncedResource.self])
        let diskConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        var persistenceWarning: String?

        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [diskConfig])
        } catch {
            // Base potentiellement corrompue : suppression du store (et sidecars SQLite) puis nouvelle tentative
            let storeURL = diskConfig.url
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(atPath: storeURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: storeURL.path + "-shm")
            do {
                container = try ModelContainer(for: schema, configurations: [diskConfig])
                persistenceWarning = "La base locale était corrompue et a été réinitialisée. Un nouveau scan complet sera nécessaire."
            } catch {
                do {
                    // Dernier recours : base en mémoire volatile pour cette session, plutôt qu'un crash au lancement
                    let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    container = try ModelContainer(for: schema, configurations: [memoryConfig])
                    persistenceWarning = "Base locale indisponible : fonctionnement en mémoire volatile pour cette session."
                } catch {
                    fatalError("Erreur d'initialisation de SwiftData: \(error.localizedDescription)")
                }
            }
        }

        self.modelContainer = container
        self.modelContext = ModelContext(container)

        self.photoObserver.delegate = self
        updateStatsFromDatabase()

        if let persistenceWarning {
            log(persistenceWarning, level: .error)
        }
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

    public func clearLogs() {
        recentLogs.removeAll()
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
                if isSyncingInProcess {
                    // Diffère les suppressions : la boucle de sync en cours peut encore référencer ces modèles.
                    pendingDeletionIDs.append(contentsOf: event.deletedAssetIDs)
                    needsFollowUpScan = true
                } else {
                    await processDeletions(assetIDs: event.deletedAssetIDs)
                }
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
            let syncedRaw = SyncStatus.synced.rawValue
            let pendingRaw = SyncStatus.pending.rawValue
            let syncingRaw = SyncStatus.syncing.rawValue
            let failedRaw = SyncStatus.failed.rawValue

            // fetchCount évite de matérialiser tous les objets en mémoire à chaque appel
            self.totalAssets = try modelContext.fetchCount(FetchDescriptor<SyncedAsset>())
            self.syncedAssetsCount = try modelContext.fetchCount(
                FetchDescriptor<SyncedAsset>(predicate: #Predicate { $0.syncStatusRaw == syncedRaw })
            )
            self.pendingAssetsCount = try modelContext.fetchCount(
                FetchDescriptor<SyncedAsset>(predicate: #Predicate {
                    $0.syncStatusRaw == pendingRaw || $0.syncStatusRaw == syncingRaw || $0.syncStatusRaw == failedRaw
                })
            )
        } catch {
            log("Erreur lors de la lecture de la base locale: \(error.localizedDescription)", level: .error)
        }
    }
    
    // MARK: - Full Library Scan
    public func performFullScan() {
        // Un nouveau cycle annule tout essai automatique planifié.
        retryTask?.cancel()
        retryTask = nil

        guard !isSyncingInProcess else {
            // Un cycle est déjà en cours : la demande sera honorée par un scan de suivi en fin de cycle.
            needsFollowUpScan = true
            return
        }
        
        syncTask = Task {
            log("Lancement du scan complet de la photothèque...", level: .info)
            let assets = photoObserver.fetchAllAssets()
            log("\(assets.count) éléments trouvés dans la photothèque.", level: .info)
            
            // Le balayage des suppressions locales n'est fiable qu'avec un accès complet :
            // en accès limité, la photothèque ne retourne qu'un sous-ensemble des assets.
            let hasFullAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            await enqueueAssetsForSync(assets, isFullScan: hasFullAccess)
        }
    }
    
    // MARK: - 2-Phase Pre-Scan & Batch Sync Processing
    private func enqueueAssetsForSync(_ assets: [PHAsset], isFullScan: Bool = false) async {
        guard !isSyncingInProcess else {
            // Un cycle est déjà en cours : ces changements seront couverts par le scan de suivi.
            needsFollowUpScan = true
            return
        }

        guard config.isValid else {
            self.state = .error("Configuration Nextcloud incomplète.")
            log("Configuration Nextcloud manquante ou invalide.", level: .warning)
            return
        }

        isSyncingInProcess = true

        guard !assets.isEmpty else {
            updateStatsFromDatabase()
            if self.pendingAssetsCount == 0 {
                self.state = .idle
            }
            finishSyncCycle()
            return
        }

        self.state = .syncing(progress: 0.0, message: "Indexation de la photothèque...")
        
        // ----------------------------------------------------
        // PHASE 1: Indexation & Décompte total des éléments à envoyer
        // ----------------------------------------------------
        var pendingAssetPairs: [(asset: PHAsset, syncedRecord: SyncedAsset)] = []
        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "yyyy"
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MM"
        
        // Single bulk fetch to avoid N individual database queries on main thread
        let existingDescriptor = FetchDescriptor<SyncedAsset>()
        let allExistingAssets = (try? modelContext.fetch(existingDescriptor)) ?? []
        var existingDict = Dictionary(allExistingAssets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })

        let fetchedLocalIDs = isFullScan ? Set(assets.map(\.localIdentifier)) : nil
        
        for (index, asset) in assets.enumerated() {
            if Task.isCancelled { break }
            
            // Progress update for indexation phase
            if index % 50 == 0 || index == assets.count - 1 {
                let indexProgress = Double(index + 1) / Double(assets.count)
                self.state = .syncing(progress: indexProgress * 0.1, message: "Analyse \(index + 1) / \(assets.count)...")
            }
            
            let localID = asset.localIdentifier
            let existing = existingDict[localID]
            
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
                existingDict[localID] = targetAsset
            }
            
            pendingAssetPairs.append((asset, targetAsset))
        }
        
        try? modelContext.save()

        // Balayage des suppressions : assets présents en base mais absents de la photothèque
        // (photos supprimées pendant que l'app était fermée, ou événements manqués).
        if let fetchedLocalIDs {
            let deletedIDs = existingDict.keys.filter { !fetchedLocalIDs.contains($0) }
            if !deletedIDs.isEmpty {
                log("\(deletedIDs.count) élément(s) absents de la photothèque détecté(s) lors du scan.", level: .info)
                await processDeletions(assetIDs: Array(deletedIDs))
            }
        }

        updateStatsFromDatabase()
        
        let totalPendingToUpload = pendingAssetPairs.count
        log("\(totalPendingToUpload) élément(s) en attente d'envoi vers Nextcloud.", level: .info)
        
        if totalPendingToUpload == 0 {
            self.state = .idle
            log("Tous les éléments sont déjà à jour sur Nextcloud.", level: .success)
            finishSyncCycle()
            return
        }
        
        // ----------------------------------------------------
        // PHASE 2: Transfert vers Nextcloud avec progression réelle (X / Total)
        // Uploads concurrents bornés pour accélérer les lots de petits fichiers
        // ----------------------------------------------------
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SyncScratch_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        var completedCount = 0

        for chunkStart in stride(from: 0, to: totalPendingToUpload, by: maxConcurrentUploads) {
            if Task.isCancelled { break }

            // Check Pause state loop (granularité : lot d'uploads concurrents)
            while isPaused {
                let currentProgress = Double(completedCount) / Double(totalPendingToUpload)
                self.state = .paused(progress: currentProgress, message: "En pause (\(completedCount)/\(totalPendingToUpload))")
                try? await Task.sleep(for: .seconds(1))
            }

            let chunkEnd = min(chunkStart + maxConcurrentUploads, totalPendingToUpload)
            await withTaskGroup(of: Void.self) { group in
                for index in chunkStart..<chunkEnd {
                    let pair = pendingAssetPairs[index]
                    group.addTask {
                        await self.syncSingleAsset(pair.asset, targetAsset: pair.syncedRecord, scratchDirectory: tempDir)
                    }
                }
                for await _ in group {
                    completedCount += 1
                    let progress = Double(completedCount) / Double(totalPendingToUpload)
                    self.state = .syncing(progress: progress, message: "Envoi \(completedCount) / \(totalPendingToUpload)")
                    updateStatsFromDatabase()
                }
            }
        }
        
        self.lastSyncDate = Date()
        updateStatsFromDatabase()
        self.state = .idle

        let failedCount = pendingAssetPairs.filter { $0.syncedRecord.syncStatus == .failed }.count
        if failedCount > 0 {
            log("Synchronisation terminée avec \(failedCount) échec(s) sur \(totalPendingToUpload) élément(s).", level: .warning)
            consecutiveFailedRuns += 1
            scheduleAutomaticRetry()
        } else {
            log("Synchronisation de \(totalPendingToUpload) élément(s) terminée avec succès.", level: .success)
            consecutiveFailedRuns = 0
        }

        finishSyncCycle()
    }

    // MARK: - Nouvel essai automatique (backoff plafonné)
    private func scheduleAutomaticRetry() {
        guard consecutiveFailedRuns <= maxConsecutiveFailedRuns else {
            log("Nouvel essai automatique non planifié après \(maxConsecutiveFailedRuns) cycles infructueux. Vérifiez la configuration ou lancez un scan manuel.", level: .warning)
            return
        }
        let delaySeconds = min(60.0 * pow(2.0, Double(consecutiveFailedRuns - 1)), 600.0)
        log("Nouvel essai automatique planifié dans \(Int(delaySeconds)) s.", level: .warning)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await self?.performFullScan()
        }
    }

    // MARK: - Fin de cycle (scan de suivi + suppressions différées)
    private func finishSyncCycle() {
        isSyncingInProcess = false

        if !pendingDeletionIDs.isEmpty {
            let ids = pendingDeletionIDs
            pendingDeletionIDs.removeAll()
            Task { await processDeletions(assetIDs: ids) }
        }

        if needsFollowUpScan {
            needsFollowUpScan = false
            log("Changements détectés pendant la synchronisation : lancement d'un scan de suivi.", level: .info)
            performFullScan()
        }
    }
    
    // MARK: - Sync Single Asset (Mac -> Nextcloud)
    private func syncSingleAsset(_ asset: PHAsset, targetAsset: SyncedAsset, scratchDirectory: URL) async {
        targetAsset.syncStatus = .syncing
        try? modelContext.save()
        
        var extractedResources: [ExtractedMediaResource] = []
        defer {
            for res in extractedResources {
                try? FileManager.default.removeItem(at: res.fileURL)
            }
        }
        
        do {
            extractedResources = try await photoObserver.extractResources(for: asset, scratchDirectory: scratchDirectory)
            
            // Clear prior resources to avoid duplicate SyncedResource items on retry
            targetAsset.resources.removeAll()
            
            for resource in extractedResources {
                let remoteFilePath = "\(targetAsset.remotePath)/\(resource.originalFilename)"
                
                log("Upload de \(resource.originalFilename) (\(ByteCountFormatter.string(fromByteCount: resource.fileSize, countStyle: .file)))...", level: .info)
                
                try await webDavService.uploadFile(localFileURL: resource.fileURL, remoteRelativePath: remoteFilePath) { _ in
                    // Sub progress
                }
                
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
        for localID in assetIDs {
            let descriptor = FetchDescriptor<SyncedAsset>(predicate: #Predicate { $0.localIdentifier == localID })
            guard let found = try? modelContext.fetch(descriptor).first else { continue }

            if config.deleteRemoteOnLocalDelete {
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
            } else {
                log("Suppression distante ignorée (Option désactivée dans les réglages).", level: .info)
            }

            // Le suivi local est toujours supprimé : l'asset n'existe plus dans la photothèque.
            modelContext.delete(found)
            try? modelContext.save()
        }

        updateStatsFromDatabase()
    }
}
