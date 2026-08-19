//
//  AppUpdater.swift
//  iCloudPhoto2Nextcloud
//

import Foundation
import CryptoKit
import AppKit

/// Erreurs du mécanisme de mise à jour automatique.
public nonisolated enum UpdateError: LocalizedError, Sendable {
    case invalidURL
    case httpStatus(Int)
    case noAssetForArchitecture(String)
    case missingChecksum
    case checksumMismatch
    case unzipFailed
    case bundleNotFound
    case destinationNotWritable(String)
    case network(Error)
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "URL de la release invalide.")
        case .httpStatus(let code):
            return String(localized: "Réponse HTTP inattendue du serveur de release (\(code)).")
        case .noAssetForArchitecture(let arch):
            return String(localized: "Aucun binaire de mise à jour pour cette architecture (\(arch)).")
        case .missingChecksum:
            return String(localized: "Empreinte SHA-256 absente de la release : mise à jour refusée.")
        case .checksumMismatch:
            return String(localized: "Empreinte SHA-256 incorrecte : fichier téléchargé corrompu ou compromis.")
        case .unzipFailed:
            return String(localized: "Échec de la décompression de la mise à jour.")
        case .bundleNotFound:
            return String(localized: "Application introuvable dans l'archive de mise à jour.")
        case .destinationNotWritable(let path):
            return String(localized: "Impossible d'écrire dans \(path) : autorisations insuffisantes.")
        case .network(let error):
            return String(localized: "Erreur réseau : \(error.localizedDescription)")
        }
    }
}

/// Asset d'une release GitHub.
public nonisolated struct ReleaseAsset: Sendable, Equatable, Codable {
    public let name: String
    public let browserDownloadURL: String
    
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
    
    public init(name: String, browserDownloadURL: String) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
    }
}

/// Informations de la dernière release GitHub.
public nonisolated struct ReleaseInfo: Sendable, Equatable, Codable {
    public let tagName: String
    public let body: String?
    public let assets: [ReleaseAsset]
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }
    
    public init(tagName: String, body: String?, assets: [ReleaseAsset]) {
        self.tagName = tagName
        self.body = body
        self.assets = assets
    }
}

public nonisolated enum UpdateCheckResult: Sendable, Equatable {
    case upToDate
    case available(ReleaseInfo)
}

/// Mécanisme de mise à jour automatique basé sur les releases GitHub.
/// Chaque build CI publie une release `ci-<sha>` contenant les trois binaires
/// et un tableau markdown avec leurs empreintes SHA-256 dans le corps de la release.
public nonisolated enum AppUpdater {
    private static let repo = "nitatemic/iCloudPhoto2Nextcloud"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    
    /// Tag de la dernière mise à jour installée (utilisé si l'app n'est pas estampillée par la CI).
    public static let installedTagKey = "nc_installed_release_tag"
    /// Préférence : vérification des mises à jour au lancement.
    public static let checkOnLaunchKey = "nc_check_updates_on_launch"
    
    /// Tag `ci-<sha>` estampillé dans le bundle par la CI (clé `CIBuildTag`).
    public static var currentBuildTag: String? {
        if let tag = Bundle.main.infoDictionary?["CIBuildTag"] as? String,
           tag.hasPrefix("ci-") { return tag }
        // Compatibilité : les builds antérieurs à l'introduction de `CIBuildTag`
        // portaient le tag dans CFBundleVersion.
        guard let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
              version.hasPrefix("ci-") else { return nil }
        return version
    }
    
    // MARK: - API GitHub
    
    /// Interroge la dernière release publiée.
    public static func latestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iCloudPhoto2Nextcloud-updater/1.0", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw UpdateError.httpStatus(http.statusCode)
            }
            return try JSONDecoder().decode(ReleaseInfo.self, from: data)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error)
        }
    }
    
    /// Compare la dernière release au build installé (tag CI, sinon tag enregistré localement).
    public static func checkForUpdate() async throws -> UpdateCheckResult {
        let release = try await latestRelease()
        let knownTag = currentBuildTag ?? UserDefaults.standard.string(forKey: installedTagKey)
        if let knownTag, knownTag == release.tagName {
            return .upToDate
        }
        return .available(release)
    }
    
    // MARK: - Sélection du binaire
    
    /// Architecture matérielle courante (`arm64` / `x86_64`).
    public static var currentArchitecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
    
    /// Choisit l'asset adapté à l'architecture (Apple Silicon / Intel), universel en repli.
    public static func selectAsset(for architecture: String, assets: [ReleaseAsset]) -> ReleaseAsset? {
        switch architecture {
        case "arm64", "arm64e":
            return assets.first { $0.name.contains("AppleSilicon") }
                ?? assets.first { $0.name.contains("Universal") }
        case "x86_64", "x86_64h":
            return assets.first { $0.name.contains("Intel") }
                ?? assets.first { $0.name.contains("Universal") }
        default:
            return assets.first { $0.name.contains("Universal") }
        }
    }
    
    /// Extrait l'empreinte SHA-256 d'un asset depuis le corps de la release
    /// (ligne markdown `| <fichier> | <arch> | <hex-64> |` générée par la CI).
    public static func sha256ForAsset(named filename: String, in body: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: filename)
        let pattern = #"\|[^\|]*\#(escaped)[^\|]*\|[^\|]*\|[ ]*([0-9a-fA-F]{64})[ ]*\|"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              let hexRange = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[hexRange])
    }
    
    // MARK: - Téléchargement, vérification, installation
    
    /// Télécharge la dernière release adaptée à l'architecture, vérifie son empreinte
    /// SHA-256, remplace l'application courante puis la relance.
    /// - Parameter progress: callback de progression (journalisé par le moteur).
    public static func downloadAndInstall(release: ReleaseInfo, progress: @escaping (String) -> Void) async throws {
        let arch = currentArchitecture
        guard let asset = selectAsset(for: arch, assets: release.assets) else {
            throw UpdateError.noAssetForArchitecture(arch)
        }
        guard let body = release.body,
              let expectedHash = sha256ForAsset(named: asset.name, in: body) else {
            throw UpdateError.missingChecksum
        }
        
        progress(String(localized: "Téléchargement de \(asset.name)..."))
        let zipURL = try await download(asset: asset)
        defer { try? FileManager.default.removeItem(at: zipURL) }
        
        let actualHash = try sha256(of: zipURL)
        guard actualHash.lowercased() == expectedHash.lowercased() else {
            throw UpdateError.checksumMismatch
        }
        
        progress(String(localized: "Empreinte SHA-256 vérifiée, installation..."))
        let unzipDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdate_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unzipDirectory) }
        
        try await unzip(zipURL: zipURL, to: unzipDirectory)
        guard let newAppURL = findApp(in: unzipDirectory) else {
            throw UpdateError.bundleNotFound
        }
        
        let currentBundleURL = Bundle.main.bundleURL
        try replaceBundle(current: currentBundleURL, with: newAppURL)
        
        UserDefaults.standard.set(release.tagName, forKey: installedTagKey)
        progress(String(localized: "Mise à jour installée, redémarrage..."))
        relaunch(app: currentBundleURL)
    }
    
    private static func download(asset: ReleaseAsset) async throws -> URL {
        guard let url = URL(string: asset.browserDownloadURL) else {
            throw UpdateError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("iCloudPhoto2Nextcloud-updater/1.0", forHTTPHeaderField: "User-Agent")
        
        do {
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw UpdateError.httpStatus(http.statusCode)
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + asset.name)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            return destination
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error)
        }
    }
    
    /// Empreinte SHA-256 d'un fichier (flux pour les gros fichiers).
    public static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20) {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    
    private static func unzip(zipURL: URL, to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, directory.path]
        let status = try await runProcess(process)
        guard status == 0 else { throw UpdateError.unzipFailed }
    }
    
    private static func runProcess(_ process: Process) async throws -> Int32 {
        do {
            try process.run()
        } catch {
            throw UpdateError.network(error)
        }
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        }
    }
    
    private static func findApp(in directory: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension == "app" }
    }
    
    /// Remplace le bundle courant par le nouveau (l'ancien est déplacé de côté,
    /// restauré en cas d'échec de copie).
    private static func replaceBundle(current: URL, with new: URL) throws {
        let fileManager = FileManager.default
        let parent = current.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw UpdateError.destinationNotWritable(parent.path)
        }
        
        let backupURL = parent.appendingPathComponent(current.lastPathComponent + ".update.bak")
        try? fileManager.removeItem(at: backupURL)
        
        do {
            try fileManager.moveItem(at: current, to: backupURL)
            try fileManager.copyItem(at: new, to: current)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            try? fileManager.moveItem(at: backupURL, to: current)
            throw error
        }
    }
    
    /// Relance l'application après l'installation (via `open -n` pour forcer
    /// un nouveau processus une fois l'ancien terminé).
    private static func relaunch(app: URL) {
        let escapedPath = app.path.replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open -n \"\(escapedPath)\""]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }
}
