//
//  NextcloudWebDAVService.swift
//  iCloudPhoto2Nextcloud
//

import Foundation

public enum WebDAVError: LocalizedError, Sendable {
    case invalidConfig
    case invalidURL(String)
    case httpError(statusCode: Int, message: String)
    case chunkingFailed(String)
    case networkError(Error)
    case fileNotFound
    
    public var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "Configuration Nextcloud manquante ou invalide."
        case .invalidURL(let path):
            return "URL WebDAV invalide pour le chemin: \(path)"
        case .httpError(let statusCode, let message):
            return "Erreur HTTP WebDAV (\(statusCode)): \(message)"
        case .chunkingFailed(let detail):
            return "Échec du découpage/upload par morceaux: \(detail)"
        case .networkError(let error):
            return "Erreur réseau: \(error.localizedDescription)"
        case .fileNotFound:
            return "Le fichier distant n'existe pas."
        }
    }
}

/// Service handling Nextcloud WebDAV communications (MKCOL, PUT, DELETE, Chunking)
public actor NextcloudWebDAVService {
    private var config: NextcloudConfig
    private let session: URLSession
    
    // WebDAV v2 Chunk size threshold (10 MB)
    private let chunkSizeThreshold: Int64 = 10 * 1024 * 1024
    private let chunkSize: Int64 = 5 * 1024 * 1024 // 5 MB chunks
    
    public init(config: NextcloudConfig = .loadFromKeychain()) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = false // Set to false to avoid infinite waiting
        sessionConfig.timeoutIntervalForRequest = 15 // 15 seconds request timeout
        sessionConfig.timeoutIntervalForResource = 300 // 5 minutes resource timeout
        self.session = URLSession(configuration: sessionConfig)
    }
    
    public func updateConfig(_ newConfig: NextcloudConfig) {
        self.config = newConfig
    }
    
    // MARK: - Basic WebDAV Header Helper
    private func authHeader() -> String {
        let credential = "\(config.username):\(config.appPassword)"
        let data = Data(credential.utf8)
        return "Basic " + data.base64EncodedString()
    }
    
    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("iCloudPhoto2Nextcloud-macOS/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }
    
    // MARK: - Connection Test (PROPFIND)
    public func testConnection() async throws -> Bool {
        guard let baseURL = config.webDavBaseURL else {
            throw WebDAVError.invalidConfig
        }
        
        var request = makeRequest(url: baseURL, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
        
        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 207
            }
            return false
        } catch {
            throw WebDAVError.networkError(error)
        }
    }
    
    // MARK: - MKCOL (Create Remote Folders Recursively)
    public func createDirectory(path: String) async throws {
        guard let baseURL = config.webDavBaseURL else {
            throw WebDAVError.invalidConfig
        }
        
        let components = path.split(separator: "/").map { String($0) }
        var currentPath = baseURL
        
        for component in components {
            currentPath = currentPath.appendingPathComponent(component, isDirectory: true)
            var request = makeRequest(url: currentPath, method: "MKCOL")
            
            do {
                let (_, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    // 201 = Created, 405 = Method Not Allowed (Already Exists)
                    if httpResponse.statusCode != 201 && httpResponse.statusCode != 405 {
                        if httpResponse.statusCode >= 400 {
                            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: "Échec création dossier \(component)")
                        }
                    }
                }
            } catch {
                throw WebDAVError.networkError(error)
            }
        }
    }
    
    // MARK: - PUT File Upload (Direct or WebDAV v2 Chunked)
    public func uploadFile(localFileURL: URL, remoteRelativePath: String, progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let baseURL = config.webDavBaseURL else {
            throw WebDAVError.invalidConfig
        }
        
        // Ensure remote parent folder exists
        let folderPath = (remoteRelativePath as NSString).deletingLastPathComponent
        if !folderPath.isEmpty && folderPath != "." {
            try await createDirectory(path: folderPath)
        }
        
        let fileSize: Int64
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: localFileURL.path)
            fileSize = (attr[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw WebDAVError.networkError(error)
        }
        
        let targetURL = baseURL.appendingPathComponent(remoteRelativePath)
        
        // If file > 10 MB, use Nextcloud Chunked Upload v2
        if fileSize > chunkSizeThreshold {
            try await uploadFileChunked(localFileURL: localFileURL, remoteRelativePath: remoteRelativePath, fileSize: fileSize, progressHandler: progressHandler)
        } else {
            try await uploadFileDirect(localFileURL: localFileURL, targetURL: targetURL, progressHandler: progressHandler)
        }
    }
    
    // MARK: - Direct PUT Upload
    private func uploadFileDirect(localFileURL: URL, targetURL: URL, progressHandler: (@Sendable (Double) -> Void)?) async throws {
        var request = makeRequest(url: targetURL, method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        
        do {
            let (_, response) = try await session.upload(for: request, fromFile: localFileURL)
            if let httpResponse = response as? HTTPURLResponse {
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: "Échec d'upload PUT direct (\(httpResponse.statusCode))")
                }
            }
            progressHandler?(1.0)
        } catch {
            throw WebDAVError.networkError(error)
        }
    }
    
    // MARK: - WebDAV Chunked Upload v2 (For large files/videos)
    private func uploadFileChunked(localFileURL: URL, remoteRelativePath: String, fileSize: Int64, progressHandler: (@Sendable (Double) -> Void)?) async throws {
        var serverRoot = config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverRoot.isEmpty else {
            throw WebDAVError.invalidConfig
        }
        if !serverRoot.hasPrefix("http://") && !serverRoot.hasPrefix("https://") {
            serverRoot = "https://" + serverRoot
        }
        while serverRoot.hasSuffix("/") { serverRoot.removeLast() }
        
        let transferID = UUID().uuidString
        let uploadsPath = "/remote.php/dav/uploads/\(config.username)/\(transferID)"
        guard let uploadsURL = URL(string: serverRoot + uploadsPath) else {
            throw WebDAVError.invalidURL(uploadsPath)
        }
        
        // 1. Create upload session directory
        var mkcolReq = makeRequest(url: uploadsURL, method: "MKCOL")
        let (_, mkcolResp) = try await session.data(for: mkcolReq)
        if let http = mkcolResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WebDAVError.httpError(statusCode: http.statusCode, message: "Impossible d'initier l'upload par morceaux Nextcloud")
        }
        
        // 2. Upload chunks
        let fileHandle = try FileHandle(forReadingFrom: localFileURL)
        defer { try? fileHandle.close() }
        
        var offset: Int64 = 0
        var chunkIndex = 0
        
        while offset < fileSize {
            let currentChunkSize = min(chunkSize, fileSize - offset)
            try fileHandle.seek(toOffset: UInt64(offset))
            let chunkData = fileHandle.readData(ofLength: Int(currentChunkSize))
            
            let chunkStart = String(format: "%016d", offset)
            let chunkEnd = String(format: "%016d", offset + currentChunkSize - 1)
            let chunkURL = uploadsURL.appendingPathComponent("\(chunkStart)-\(chunkEnd)")
            
            var chunkReq = makeRequest(url: chunkURL, method: "PUT")
            chunkReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            
            let (_, chunkResp) = try await session.upload(for: chunkReq, from: chunkData)
            if let http = chunkResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw WebDAVError.httpError(statusCode: http.statusCode, message: "Erreur lors du transfert du morceau \(chunkIndex)")
            }
            
            offset += currentChunkSize
            chunkIndex += 1
            progressHandler?(Double(offset) / Double(fileSize))
        }
        
        // 3. Assemble chunks via MOVE
        guard let destinationURL = config.webDavBaseURL?.appendingPathComponent(remoteRelativePath) else {
            throw WebDAVError.invalidConfig
        }
        
        let destinationPath = destinationURL.path
        let moveSourceURL = uploadsURL.appendingPathComponent(".file")
        var moveReq = makeRequest(url: moveSourceURL, method: "MOVE")
        moveReq.setValue(destinationPath, forHTTPHeaderField: "Destination")
        
        let (_, moveResp) = try await session.data(for: moveReq)
        if let http = moveResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WebDAVError.httpError(statusCode: http.statusCode, message: "Échec de l'assemblage des morceaux sur Nextcloud")
        }
    }
    
    // MARK: - DELETE Remote File
    public func deleteFile(remoteRelativePath: String) async throws {
        guard let baseURL = config.webDavBaseURL else {
            throw WebDAVError.invalidConfig
        }
        
        let targetURL = baseURL.appendingPathComponent(remoteRelativePath)
        let request = makeRequest(url: targetURL, method: "DELETE")
        
        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    return
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: "Échec de suppression du fichier distant: \(remoteRelativePath)")
                }
            }
        } catch {
            throw WebDAVError.networkError(error)
        }
    }
}
