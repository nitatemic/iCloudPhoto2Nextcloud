//
//  SyncEngine.swift
//  iCloudPhoto2Nextcloud
//

import Foundation
import SwiftData
import Photos
import Combine
import SwiftUI

public nonisolated enum EngineState: Equatable, Sendable {
    case idle
    case syncing(progress: Double, message: String)
    case paused(progress: Double, message: String)
    case verifying(progress: Double, message: String)
    case unauthorized
    case error(String)
}

/// Identifiants Sendable d'un élément à uploader — capturés par les tâches du group
/// (évite d'envoyer des objets non-Sendable à travers l'isolation `any` d'addTask).
private struct SyncWorkItem: Sendable {
    let localIdentifier: String
    let persistentModelID: PersistentIdentifier
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
    /// Derniers assets synchronisés (localIdentifier), du plus récent au plus ancien — alimente les miniatures du menu.
    public var recentSyncedIDs: [String] = []
    public var isPaused: Bool = false
    
    public var config: NextcloudConfig {
        didSet {
            Task {
                await webDavService.updateConfig(config)
            }
            restartVerificationScheduler()
        }
    }
    
    /// Dernière vérification d'intégrité de la sauvegarde terminée (persistée entre sessions).
    public private(set) var lastVerificationDate: Date? {
        didSet {
            if let lastVerificationDate {
                UserDefaults.standard.set(lastVerificationDate.timeIntervalSince1970, forKey: Self.lastVerificationKey)
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
    /// Vrai pendant un scan de vérification de la sauvegarde (affiche l'état .verifying).
    private var isVerifying = false
    /// Tâche de vérification périodique de la sauvegarde.
    private var schedulerTask: Task<Void, Never>?
    private static let lastVerificationKey = "nc_last_verification"
    private static let schedulerTick: Duration = .seconds(3600)
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
    /// Nombre de miniatures récentes conservées pour le menu.
    private let maxRecentSyncedThumbnails = 10

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
                persistenceWarning = String(localized: "La base locale était corrompue et a été réinitialisée. Un nouveau scan complet sera nécessaire.")
            } catch {
                do {
                    // Dernier recours : base en mémoire volatile pour cette session, plutôt qu'un crash au lancement
                    let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    container = try ModelContainer(for: schema, configurations: [memoryConfig])
                    persistenceWarning = String(localized: "Base locale indisponible : fonctionnement en mémoire volatile pour cette session.")
                } catch {
                    fatalError("Erreur d'initialisation de SwiftData: \(error.localizedDescription)")
                }
            }
        }

        self.modelContainer = container
        self.modelContext = ModelContext(container)

        self.photoObserver.delegate = self
        let storedVerification = UserDefaults.standard.object(forKey: Self.lastVerificationKey) as? TimeInterval
        self.lastVerificationDate = storedVerification.map(Date.init(timeIntervalSince1970:))
        updateStatsFromDatabase()
        loadRecentSyncedThumbnails()

        if let persistenceWarning {
            log(persistenceWarning, level: .error)
        }
    }
    
    // MARK: - App Lifecycle Start
    public func startEngine() {
        log(String(localized: "Démarrage du moteur de synchronisation..."), level: .info)
        photoObserver.startObserving()
        restartVerificationScheduler()
        checkScheduledVerification()
        checkForUpdateIfEnabled()
        
        Task {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined {
                let newStatus = await photoObserver.requestAuthorization()
                if newStatus == .authorized || newStatus == .limited {
                    performFullScan()
                } else {
                    self.state = .unauthorized
                    log(String(localized: "Accès aux photos refusé. Veuillez accorder la permission dans Réglages Système."), level: .error)
                }
            } else if status == .denied || status == .restricted {
                self.state = .unauthorized
                log(String(localized: "Accès aux photos refusé. Veuillez accorder la permission dans Réglages Système."), level: .error)
            } else {
                performFullScan()
            }
        }
    }
    
    /// Vérifie la présence d'une mise à jour au lancement (si activé dans les réglages).
    /// Silencieuse : le résultat est journalisé, jamais affiché en alerte.
    private func checkForUpdateIfEnabled() {
        guard UserDefaults.standard.object(forKey: AppUpdater.checkOnLaunchKey) as? Bool ?? true else { return }
        Task {
            do {
                let result = try await AppUpdater.checkForUpdate()
                if case .available(let release) = result {
                    log(String(localized: "Mise à jour disponible : \(release.tagName). Menu → « Rechercher une mise à jour »."), level: .info)
                }
            } catch {
                // Échec discret au lancement (hors ligne, API indisponible...)
                log(String(localized: "Vérification des mises à jour impossible : \(error.localizedDescription)"), level: .warning)
            }
        }
    }
    
    /// Annule les tâches en cours (appelé avant la fermeture de l'app pour
    /// éviter de couper un upload en plein transfert).
    public func stopEngine() {
        syncTask?.cancel()
        syncTask = nil
        retryTask?.cancel()
        retryTask = nil
        schedulerTask?.cancel()
        schedulerTask = nil
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
            state = .paused(progress: progress, message: String(localized: "Synchronisation en pause"))
        } else {
            state = .paused(progress: 0.0, message: String(localized: "Synchronisation en pause"))
        }
        log(String(localized: "Mise en pause de la synchronisation."), level: .warning)
    }
    
    public func resumeSync() {
        guard isPaused else { return }
        isPaused = false
        log(String(localized: "Reprise de la synchronisation."), level: .info)
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
            if status == .limited {
                log(String(localized: "Accès aux photos autorisé (limité)."), level: .info)
            } else {
                log(String(localized: "Accès aux photos autorisé (complet)."), level: .info)
            }
            performFullScan()
        } else if status == .denied || status == .restricted {
            self.state = .unauthorized
            log(String(localized: "Accès aux photos révoqué."), level: .error)
        }
    }
    
    public func photoObserver(_ observer: PhotoObserver, didReceiveChangeEvent event: PhotoChangeEvent) {
        log(String(localized: "Changement PhotoKit détecté: +\(event.insertedAssets.count), ~\(event.updatedAssets.count), -\(event.deletedAssetIDs.count)"), level: .info)
        
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
            log(String(localized: "Erreur lors de la lecture de la base locale: \(error.localizedDescription)"), level: .error)
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
            log(String(localized: "Lancement du scan complet de la photothèque..."), level: .info)
            let assets = photoObserver.fetchAllAssets()
            log(String(localized: "\(assets.count) éléments trouvés dans la photothèque."), level: .info)
            
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
            self.state = .error(String(localized: "Configuration Nextcloud incomplète."))
            log(String(localized: "Configuration Nextcloud manquante ou invalide."), level: .warning)
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

        self.state = .syncing(progress: 0.0, message: String(localized: "Indexation de la photothèque..."))
        
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
                self.state = .syncing(progress: indexProgress * 0.1, message: String(localized: "Analyse \(index + 1) / \(assets.count)..."))
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
                log(String(localized: "\(deletedIDs.count) élément(s) absents de la photothèque détecté(s) lors du scan."), level: .info)
                await processDeletions(assetIDs: Array(deletedIDs))
            }
        }

        updateStatsFromDatabase()
        
        let totalPendingToUpload = pendingAssetPairs.count
        log(String(localized: "\(totalPendingToUpload) élément(s) en attente d'envoi vers Nextcloud."), level: .info)
        
        if totalPendingToUpload == 0 {
            self.state = .idle
            log(String(localized: "Tous les éléments sont déjà à jour sur Nextcloud."), level: .success)
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
                self.state = .paused(progress: currentProgress, message: String(localized: "En pause (\(completedCount)/\(totalPendingToUpload))"))
                try? await Task.sleep(for: .seconds(1))
            }

            let chunkEnd = min(chunkStart + maxConcurrentUploads, totalPendingToUpload)
            let chunk = Array(pendingAssetPairs[chunkStart..<chunkEnd])
            await uploadChunk(chunk, scratchDirectory: tempDir)

            completedCount += chunk.count
            let progress = Double(completedCount) / Double(totalPendingToUpload)
            self.state = .syncing(progress: progress, message: String(localized: "Envoi \(completedCount) / \(totalPendingToUpload)"))
            updateStatsFromDatabase()
        }
        
        self.lastSyncDate = Date()
        updateStatsFromDatabase()
        self.state = .idle

        let failedCount = pendingAssetPairs.filter { $0.syncedRecord.syncStatus == .failed }.count
        if failedCount > 0 {
            log(String(localized: "Synchronisation terminée avec \(failedCount) échec(s) sur \(totalPendingToUpload) élément(s)."), level: .warning)
            consecutiveFailedRuns += 1
            scheduleAutomaticRetry()
        } else {
            log(String(localized: "Synchronisation de \(totalPendingToUpload) élément(s) terminée avec succès."), level: .success)
            consecutiveFailedRuns = 0
        }

        finishSyncCycle()
    }

    // MARK: - Nouvel essai automatique (backoff plafonné)
    /// Envoie une tranche d'assets avec un nombre borné d'uploads concurrents.
    private func uploadChunk(_ pairs: [(asset: PHAsset, syncedRecord: SyncedAsset)], scratchDirectory: URL) async {
        await withTaskGroup(of: Void.self) { group in
            for pair in pairs {
                let workItem = SyncWorkItem(
                    localIdentifier: pair.asset.localIdentifier,
                    persistentModelID: pair.syncedRecord.persistentModelID
                )
                group.addTask {
                    await self.processWorkItem(workItem, scratchDirectory: scratchDirectory)
                }
            }
        }
    }

    /// Traitement MainActor d'un élément d'upload (objets récupérés ici pour
    /// ne transporter que des valeurs Sendable à travers l'isolation `any` du group).
    private func processWorkItem(_ workItem: SyncWorkItem, scratchDirectory: URL) async {
        guard let record = modelContext.model(for: workItem.persistentModelID) as? SyncedAsset else { return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [workItem.localIdentifier], options: nil).firstObject else { return }
        await syncSingleAsset(asset, targetAsset: record, scratchDirectory: scratchDirectory)
    }

    private func scheduleAutomaticRetry() {
        guard consecutiveFailedRuns <= maxConsecutiveFailedRuns else {
            log(String(localized: "Nouvel essai automatique non planifié après \(maxConsecutiveFailedRuns) cycles infructueux. Vérifiez la configuration ou lancez un scan manuel."), level: .warning)
            return
        }
        let delaySeconds = min(60.0 * pow(2.0, Double(consecutiveFailedRuns - 1)), 600.0)
        log(String(localized: "Nouvel essai automatique planifié dans \(Int(delaySeconds)) s."), level: .warning)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            self?.performFullScan()
        }
    }

    // MARK: - Miniatures récentes (menu)
    /// Recharge les derniers assets synchronisés depuis la base locale (survit au redémarrage).
    private func loadRecentSyncedThumbnails() {
        let syncedRaw = SyncStatus.synced.rawValue
        var descriptor = FetchDescriptor<SyncedAsset>(predicate: #Predicate { $0.syncStatusRaw == syncedRaw })
        descriptor.sortBy = [SortDescriptor(\.lastSyncedAt, order: .reverse)]
        descriptor.fetchLimit = maxRecentSyncedThumbnails
        recentSyncedIDs = (try? modelContext.fetch(descriptor))?.map(\.localIdentifier) ?? []
    }

    // MARK: - Vérification de la sauvegarde (intégrité distante)
    /// Déclenche un scan complet : chaque dossier `yyyy/MM` connu en base est listé sur
    /// Nextcloud puis comparé (présence + taille) aux fichiers attendus. Les éléments
    /// endommagés sont marqués `failed`, puis renvoyés par un cycle de sync de réparation.
    public func performIntegrityVerification() {
        guard config.isValid else {
            self.state = .error(String(localized: "Configuration Nextcloud incomplète."))
            log(String(localized: "Vérification impossible : configuration Nextcloud manquante ou invalide."), level: .warning)
            return
        }
        guard !isSyncingInProcess else {
            log(String(localized: "Vérification de la sauvegarde impossible pendant une synchronisation en cours."), level: .warning)
            return
        }

        isSyncingInProcess = true
        isVerifying = true
        log(String(localized: "Lancement de la vérification de la sauvegarde sur Nextcloud..."), level: .info)
        self.state = .verifying(progress: 0.0, message: String(localized: "Vérification de la sauvegarde..."))

        syncTask = Task {
            await runBackupVerification()
        }
    }
    
    private func runBackupVerification() async {
        do {
            let syncedRaw = SyncStatus.synced.rawValue
            let descriptor = FetchDescriptor<SyncedAsset>(predicate: #Predicate { $0.syncStatusRaw == syncedRaw })
            let syncedAssets = (try? modelContext.fetch(descriptor)) ?? []

            if syncedAssets.isEmpty {
                log(String(localized: "Aucun élément synchronisé à vérifier."), level: .info)
                lastVerificationDate = Date()
                isVerifying = false
                state = .idle
                finishSyncCycle()
                return
            }

            let assetsByFolder = Dictionary(grouping: syncedAssets, by: \.remotePath)
            let folders = assetsByFolder.keys.sorted()
            let totalResources = syncedAssets.reduce(0) { $0 + $1.resources.count }

            var remoteFilesByFolder: [String: [RemoteFileInfo]] = [:]
            var processedResources = 0

            for (folderIndex, folder) in folders.enumerated() {
                if Task.isCancelled { break }

                // Pause (granularité : un dossier de la photothèque)
                while isPaused {
                    let currentProgress = totalResources == 0 ? 0 : Double(processedResources) / Double(totalResources)
                    state = .paused(progress: currentProgress, message: String(localized: "Vérification en pause"))
                    try? await Task.sleep(for: .seconds(1))
                }

                remoteFilesByFolder[folder] = try await webDavService.listDirectory(remoteRelativePath: folder)
                if Task.isCancelled { break }

                processedResources += assetsByFolder[folder]?.reduce(0) { $0 + $1.resources.count } ?? 0
                let progress = totalResources == 0 ? 0 : Double(processedResources) / Double(totalResources)
                state = .verifying(progress: progress, message: String(localized: "Vérification \(folderIndex + 1) / \(folders.count) dossiers"))
            }

            if Task.isCancelled {
                log(String(localized: "Vérification de la sauvegarde annulée."), level: .warning)
                isVerifying = false
                finishSyncCycle()
                return
            }

            let infos = syncedAssets.map { asset in
                SyncedAssetInfo(
                    localIdentifier: asset.localIdentifier,
                    remotePath: asset.remotePath,
                    resources: asset.resources.map {
                        SyncedResourceInfo(remoteFilename: $0.remoteFilename, fileSize: $0.fileSize)
                    }
                )
            }
            let report = BackupVerifier.evaluateVerification(assets: infos, remoteFilesByFolder: remoteFilesByFolder)

            // Marque les assets endommagés : le cycle de sync suivant les renverra.
            for asset in syncedAssets {
                let assetMissing = report.missingFiles.filter { $0.hasPrefix("\(asset.remotePath)/") }
                let assetMismatches = report.sizeMismatches.filter { $0.filename.hasPrefix("\(asset.remotePath)/") }
                guard !assetMissing.isEmpty || !assetMismatches.isEmpty else { continue }

                asset.syncStatus = .failed
                if let firstMissing = assetMissing.first {
                    asset.errorMessage = String(localized: "Fichier manquant sur le serveur (vérification) : \(firstMissing)")
                } else if let firstMismatch = assetMismatches.first {
                    asset.errorMessage = String(localized: "Taille incohérente sur le serveur (vérification) : \(firstMismatch.filename)")
                }
                recentSyncedIDs.removeAll { $0 == asset.localIdentifier }
            }
            try? modelContext.save()

            for file in report.missingFiles {
                log(String(localized: "Fichier manquant sur Nextcloud détecté : \(file)"), level: .error)
            }
            for mismatch in report.sizeMismatches {
                log(String(localized: "Taille incohérente pour \(mismatch.filename) (attendu \(mismatch.expectedSize), trouvé \(mismatch.foundSize))"), level: .error)
            }

            lastVerificationDate = Date()

            let damagedCount = report.damagedLocalIDs.count
            if damagedCount > 0 {
                log(String(localized: "Vérification terminée : \(damagedCount) élément(s) endommagé(s) sur \(report.checkedResourceCount) fichier(s) contrôlé(s). Ré-upload planifié."), level: .warning)
            } else {
                log(String(localized: "Vérification terminée : \(report.checkedResourceCount) fichier(s) contrôlé(s), aucun problème détecté."), level: .success)
            }
            if !report.orphanFiles.isEmpty {
                let examples = report.orphanFiles.prefix(5).joined(separator: ", ")
                log(String(localized: "\(report.orphanFiles.count) fichier(s) non tracé(s) en base présents sur le serveur (signalés, non supprimés) : \(examples)"), level: .info)
            }

            isVerifying = false
            state = .idle
            finishSyncCycle()

            if damagedCount > 0 {
                log(String(localized: "Lancement de la synchronisation de réparation..."), level: .info)
                performFullScan()
            }
        } catch {
            log(String(localized: "Erreur pendant la vérification de la sauvegarde : \(error.localizedDescription)"), level: .error)
            isVerifying = false
            state = .idle
            finishSyncCycle()
        }
    }
    
    // MARK: - Vérification périodique programmée    /// Redémarre la boucle de planification après un changement de config ou au lancement.
    private func restartVerificationScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.schedulerTick)
                guard !Task.isCancelled else { return }
                self?.checkScheduledVerification()
            }
        }
    }
    
    /// Vérifie si une vérification périodique est due (config activée + échéance dépassée + moteur libre).
    private func checkScheduledVerification() {
        guard config.autoVerifyEnabled, config.isValid else { return }
        guard !isSyncingInProcess, !isVerifying else { return }
        let intervalSeconds = TimeInterval(max(config.verifyIntervalDays, 1) * 86_400)
        if let last = lastVerificationDate, Date().timeIntervalSince(last) < intervalSeconds {
            return
        }
        log(String(localized: "Vérification périodique de la sauvegarde déclenchée."), level: .info)
        performIntegrityVerification()
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
            log(String(localized: "Changements détectés pendant la synchronisation : lancement d'un scan de suivi."), level: .info)
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
                
                log(String(localized: "Upload de \(resource.originalFilename) (\(ByteCountFormatter.string(fromByteCount: resource.fileSize, countStyle: .file)))..."), level: .info)
                
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

            // Alimente les miniatures récentes du menu
            recentSyncedIDs.removeAll { $0 == asset.localIdentifier }
            recentSyncedIDs.insert(asset.localIdentifier, at: 0)
            if recentSyncedIDs.count > maxRecentSyncedThumbnails {
                recentSyncedIDs.removeLast()
            }

            log(String(localized: "Synchronisé: \(resourceFilenameSummary(targetAsset))"), level: .success)
        } catch {
            targetAsset.syncStatus = .failed
            targetAsset.errorMessage = error.localizedDescription
            try? modelContext.save()
            log(String(localized: "Erreur sync \(asset.localIdentifier): \(error.localizedDescription)"), level: .error)
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
                log(String(localized: "Suppression distante Nextcloud pour asset supprimé: \(localID)"), level: .info)

                for resource in found.resources {
                    let remoteFilePath = "\(found.remotePath)/\(resource.remoteFilename)"
                    do {
                        try await webDavService.deleteFile(remoteRelativePath: remoteFilePath)
                        log(String(localized: "Fichier distant supprimé: \(remoteFilePath)"), level: .success)
                    } catch {
                        log(String(localized: "Erreur lors de la suppression de \(remoteFilePath): \(error.localizedDescription)"), level: .error)
                    }
                }
            } else {
                log(String(localized: "Suppression distante ignorée (Option désactivée dans les réglages)."), level: .info)
            }

            // Le suivi local est toujours supprimé : l'asset n'existe plus dans la photothèque.
            modelContext.delete(found)
            try? modelContext.save()

            recentSyncedIDs.removeAll { $0 == localID }
        }

        updateStatsFromDatabase()
    }
}
