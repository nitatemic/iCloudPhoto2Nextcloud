//
//  BackupVerification.swift
//  iCloudPhoto2Nextcloud
//

import Foundation

/// Représentation Sendable d'un asset synchronisé pour la vérification
/// (le scan ne transporte pas d'objets @Model à travers l'isolation).
public nonisolated struct SyncedAssetInfo: Sendable, Equatable {
    public let localIdentifier: String
    public let remotePath: String
    public let resources: [SyncedResourceInfo]
    
    public init(localIdentifier: String, remotePath: String, resources: [SyncedResourceInfo]) {
        self.localIdentifier = localIdentifier
        self.remotePath = remotePath
        self.resources = resources
    }
}

public nonisolated struct SyncedResourceInfo: Sendable, Equatable {
    public let remoteFilename: String
    public let fileSize: Int64
    
    public init(remoteFilename: String, fileSize: Int64) {
        self.remoteFilename = remoteFilename
        self.fileSize = fileSize
    }
}

/// Résultat du scan de vérification de la sauvegarde.
public nonisolated struct VerificationReport: Sendable, Equatable {
    /// Identifiants locaux des assets dont au moins une ressource est manquante ou de taille incohérente.
    public let damagedLocalIDs: [String]
    /// Fichiers attendus absents du serveur (chemin distant complet).
    public let missingFiles: [String]
    /// Fichiers présents mais de taille différente.
    public let sizeMismatches: [SizeMismatch]
    /// Fichiers présents sur le serveur mais non tracés en base (signalés, jamais supprimés).
    public let orphanFiles: [String]
    public let checkedResourceCount: Int
    public let checkedFolderCount: Int
    
    public struct SizeMismatch: Sendable, Equatable {
        public let filename: String
        public let expectedSize: Int64
        public let foundSize: Int64
        
        public init(filename: String, expectedSize: Int64, foundSize: Int64) {
            self.filename = filename
            self.expectedSize = expectedSize
            self.foundSize = foundSize
        }
    }
    
    public init(
        damagedLocalIDs: [String],
        missingFiles: [String],
        sizeMismatches: [SizeMismatch],
        orphanFiles: [String],
        checkedResourceCount: Int,
        checkedFolderCount: Int
    ) {
        self.damagedLocalIDs = damagedLocalIDs
        self.missingFiles = missingFiles
        self.sizeMismatches = sizeMismatches
        self.orphanFiles = orphanFiles
        self.checkedResourceCount = checkedResourceCount
        self.checkedFolderCount = checkedFolderCount
    }
}

/// Logique pure du scan d'intégrité : compare la base locale (assets synced)
/// avec le contenu listé sur le serveur. Sans réseau, sans SwiftData.
public nonisolated enum BackupVerifier {
    
    /// Compare les assets attendus avec les fichiers listés par dossier distant.
    /// - Parameters:
    ///   - assets: assets à vérifier (uniquement ceux marqués `synced` en base).
    ///   - remoteFilesByFolder: contenu réel du serveur, indexé par `remotePath`.
    public static func evaluateVerification(
        assets: [SyncedAssetInfo],
        remoteFilesByFolder: [String: [RemoteFileInfo]]
    ) -> VerificationReport {
        var damagedLocalIDs: [String] = []
        var missingFiles: [String] = []
        var sizeMismatches: [VerificationReport.SizeMismatch] = []
        var checkedResourceCount = 0
        
        // Regroupe les assets par dossier : un seul PROPFIND par dossier côté moteur.
        let assetsByFolder = Dictionary(grouping: assets, by: \.remotePath)
        
        for (remotePath, folderAssets) in assetsByFolder {
            let remoteFiles = remoteFilesByFolder[remotePath] ?? []
            let remoteByFilename = Dictionary(remoteFiles.map { ($0.filename, $0) }, uniquingKeysWith: { first, _ in first })
            
            for asset in folderAssets {
                var assetDamaged = false
                for resource in asset.resources {
                    checkedResourceCount += 1
                    let expectedPath = "\(remotePath)/\(resource.remoteFilename)"
                    
                    guard let remote = remoteByFilename[resource.remoteFilename] else {
                        missingFiles.append(expectedPath)
                        assetDamaged = true
                        continue
                    }
                    
                    if let remoteSize = remote.fileSize, remoteSize != resource.fileSize {
                        sizeMismatches.append(
                            VerificationReport.SizeMismatch(
                                filename: expectedPath,
                                expectedSize: resource.fileSize,
                                foundSize: remoteSize
                            )
                        )
                        assetDamaged = true
                    }
                }
                if assetDamaged {
                    damagedLocalIDs.append(asset.localIdentifier)
                }
            }
        }
        
        // Orphelins : fichiers sur le serveur absents de la base pour ce dossier.
        // Signalés uniquement — aucune suppression automatique.
        let expectedByFolder = assetsByFolder.mapValues { folderAssets in
            Set(folderAssets.flatMap { asset in asset.resources.map(\.remoteFilename) })
        }
        var orphanFiles: [String] = []
        for (remotePath, folderAssets) in assetsByFolder {
            guard let remoteFiles = remoteFilesByFolder[remotePath] else { continue }
            let expected = expectedByFolder[remotePath] ?? []
            for remote in remoteFiles where !expected.contains(remote.filename) {
                orphanFiles.append("\(remotePath)/\(remote.filename)")
            }
        }
        
        return VerificationReport(
            damagedLocalIDs: damagedLocalIDs,
            missingFiles: missingFiles,
            sizeMismatches: sizeMismatches,
            orphanFiles: orphanFiles,
            checkedResourceCount: checkedResourceCount,
            checkedFolderCount: assetsByFolder.count
        )
    }
}