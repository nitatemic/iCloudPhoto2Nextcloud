//
//  NextcloudWebDAVService.swift
//  iCloudPhoto2Nextcloud
//

import Foundation

public nonisolated enum WebDAVError: LocalizedError, Sendable {
    case invalidConfig
    case invalidURL(String)
    case httpError(statusCode: Int, message: String)
    case chunkingFailed(String)
    case networkError(Error)
    case fileNotFound
    case invalidResponse(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return String(localized: "Configuration Nextcloud manquante ou invalide.")
        case .invalidURL(let path):
            return String(localized: "URL WebDAV invalide pour le chemin: \(path)")
        case .httpError(let statusCode, let message):
            return String(localized: "Erreur HTTP WebDAV (\(statusCode)): \(message)")
        case .chunkingFailed(let detail):
            return String(localized: "Échec du découpage/upload par morceaux: \(detail)")
        case .networkError(let error):
            return String(localized: "Erreur réseau: \(error.localizedDescription)")
        case .fileNotFound:
            return String(localized: "Le fichier distant n'existe pas.")
        case .invalidResponse(let detail):
            return String(localized: "Réponse WebDAV invalide: \(detail)")
        }
    }
}

/// Informations renvoyées par un PROPFIND sur un fichier distant.
public nonisolated struct RemoteFileInfo: Sendable, Equatable {
    public let filename: String
    public let fileSize: Int64?
    
    public init(filename: String, fileSize: Int64?) {
        self.filename = filename
        self.fileSize = fileSize
    }
}

/// Service handling Nextcloud WebDAV communications (MKCOL, PUT, DELETE, Chunking)
public actor NextcloudWebDAVService {
    private var config: NextcloudConfig
    private let session: URLSession
    
    // WebDAV v2 Chunk size threshold (10 MB)
    private let chunkSizeThreshold: Int64 = 10 * 1024 * 1024
    private let chunkSize: Int64 = 5 * 1024 * 1024 // 5 MB chunks

    /// Dossiers distants déjà créés durant cette session (évite une chaîne de MKCOL par fichier uploadé).
    private var createdDirectories: Set<String> = []

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
        createdDirectories.removeAll()
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
    
    // MARK: - Directory Listing (PROPFIND Depth: 1)
    /// Liste les fichiers (pas les sous-dossiers) d'un dossier distant. Un dossier
    /// inexistant (404) retourne une liste vide : les éléments attendus y seront
    /// considérés comme manquants par le scan de vérification.
    public func listDirectory(remoteRelativePath: String) async throws -> [RemoteFileInfo] {
        guard let baseURL = config.webDavBaseURL else {
            throw WebDAVError.invalidConfig
        }
        
        let targetURL = buildURL(baseURL: baseURL, relativePath: remoteRelativePath)
        var request = makeRequest(url: targetURL, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindRequestBody
        
        do {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    return []
                }
                if !((200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 207) {
                    throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: String(localized: "Échec du listage du dossier \(remoteRelativePath)"))
                }
            }
            return Self.parseMultistatusResponse(data)
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }
    
    /// Corps XML de la requête PROPFIND (getcontentlength + resourcetype pour distinguer fichiers/dossiers).
    private static let propfindRequestBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:getcontentlength/>
        <d:resourcetype/>
      </d:prop>
    </d:propfind>
    """.data(using: .utf8)
    
    /// Parse une réponse multistatus PROPFIND en conservant uniquement les fichiers
    /// (href ne finissant pas par "/"), avec leur taille quand elle est fournie.
    /// Décodage percent de l'URL : les noms de fichiers peuvent contenir des espaces ou caractères spéciaux.
    nonisolated static func parseMultistatusResponse(_ data: Data) -> [RemoteFileInfo] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        
        let hrefPattern = #"<d:href>([^<]*)</d:href>"#
        let lengthPattern = #"<d:getcontentlength>\s*(\d+)\s*</d:getcontentlength>"#
        
        guard let hrefRegex = try? NSRegularExpression(pattern: hrefPattern),
              let lengthRegex = try? NSRegularExpression(pattern: lengthPattern) else { return [] }
        
        let nsString = xml as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        
        var results: [RemoteFileInfo] = []
        let hrefMatches = hrefRegex.matches(in: xml, range: fullRange)
        
        for match in hrefMatches {
            let href = nsString.substring(with: match.range(at: 1))
            guard !href.hasSuffix("/") else { continue } // dossiers ignorés
            
            var fileName = href
            if let slashRange = href.range(of: "/", options: .backwards) {
                fileName = String(href[slashRange.upperBound...])
            }
            fileName = fileName.removingPercentEncoding ?? fileName
            
            var size: Int64?
            let lengthMatch = lengthRegex.firstMatch(in: xml, options: [], range: NSRange(location: match.range.upperBound, length: nsString.length - match.range.upperBound))
            if let lengthMatch {
                let sizeString = nsString.substring(with: lengthMatch.range(at: 1))
                size = Int64(sizeString)
            }
            
            results.append(RemoteFileInfo(filename: fileName, fileSize: size))
        }
        
        return results
    }
    
    // MARK: - Helper for Multi-Component Paths
    private func buildURL(baseURL: URL, relativePath: String) -> URL {
        let components = relativePath.split(separator: "/").map { String($0) }
        var resultURL = baseURL
        for component in components {
            resultURL = resultURL.appendingPathComponent(component)
        }
        return resultURL
    }
    
    // MARK: - MKCOL (Create Remote Folders Recursively)
    public func createDirectory(path: String) async throws {
        guard let baseURL = config.webDavBaseURL else {
            throw WebDAVError.invalidConfig
        }

        // Skip si le dossier a déjà été créé durant cette session (cache invalidé au changement de config)
        guard !createdDirectories.contains(path) else { return }

        let components = path.split(separator: "/").map { String($0) }
        var currentPath = baseURL

        for component in components {
            currentPath = currentPath.appendingPathComponent(component, isDirectory: true)
            let request = makeRequest(url: currentPath, method: "MKCOL")

            do {
                let (_, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    // 201 = Created, 405 = Method Not Allowed (Already Exists)
                    if httpResponse.statusCode != 201 && httpResponse.statusCode != 405 {
                        if httpResponse.statusCode >= 400 {
                            throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: String(localized: "Échec création dossier \(component)"))
                        }
                    }
                }
            } catch let error as WebDAVError {
                throw error
            } catch {
                throw WebDAVError.networkError(error)
            }
        }

        createdDirectories.insert(path)
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

        let targetURL = buildURL(baseURL: baseURL, relativePath: remoteRelativePath)

        do {
            try await performUpload(localFileURL: localFileURL, remoteRelativePath: remoteRelativePath, targetURL: targetURL, fileSize: fileSize, progressHandler: progressHandler)
        } catch WebDAVError.httpError(let statusCode, _) where statusCode == 409 && !folderPath.isEmpty {
            // 409 Conflict : le dossier parent a probablement été supprimé côté serveur.
            // On invalide le cache local et on retente une seule fois.
            createdDirectories.remove(folderPath)
            try await createDirectory(path: folderPath)
            try await performUpload(localFileURL: localFileURL, remoteRelativePath: remoteRelativePath, targetURL: targetURL, fileSize: fileSize, progressHandler: progressHandler)
        }
    }

    /// Direct PUT for small files, WebDAV v2 chunked upload for files > 10 MB.
    private func performUpload(localFileURL: URL, remoteRelativePath: String, targetURL: URL, fileSize: Int64, progressHandler: (@Sendable (Double) -> Void)?) async throws {
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
                    throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: String(localized: "Échec d'upload PUT direct (\(httpResponse.statusCode))"))
                }
            }
            progressHandler?(1.0)
        } catch let error as WebDAVError {
            throw error
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
        let trimmedUsername = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedUsername = trimmedUsername.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedUsername
        let uploadsPath = "/remote.php/dav/uploads/\(encodedUsername)/\(transferID)"
        guard let uploadsURL = URL(string: serverRoot + uploadsPath) else {
            throw WebDAVError.invalidURL(uploadsPath)
        }

        // 1. Create upload session directory
        let mkcolReq = makeRequest(url: uploadsURL, method: "MKCOL")
        let (_, mkcolResp) = try await session.data(for: mkcolReq)
        if let http = mkcolResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WebDAVError.httpError(statusCode: http.statusCode, message: String(localized: "Impossible d'initier l'upload par morceaux Nextcloud"))
        }
        
        // 2. Upload chunks
        let fileHandle = try FileHandle(forReadingFrom: localFileURL)
        defer { try? fileHandle.close() }
        
        var offset: Int64 = 0
        var chunkIndex = 0
        
        while offset < fileSize {
            let currentChunkSize = min(chunkSize, fileSize - offset)
            
            let chunkData: Data? = try autoreleasepool {
                try fileHandle.seek(toOffset: UInt64(offset))
                return try fileHandle.read(upToCount: Int(currentChunkSize))
            }
            
            guard let chunkData = chunkData, !chunkData.isEmpty else { break }
            
            let chunkStart = String(format: "%016lld", offset)
            let chunkEnd = String(format: "%016lld", offset + Int64(chunkData.count) - 1)
            let chunkURL = uploadsURL.appendingPathComponent("\(chunkStart)-\(chunkEnd)")
            
            var chunkReq = makeRequest(url: chunkURL, method: "PUT")
            chunkReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            
            let (_, chunkResp) = try await session.upload(for: chunkReq, from: chunkData)
            if let http = chunkResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw WebDAVError.httpError(statusCode: http.statusCode, message: String(localized: "Erreur lors du transfert du morceau \(chunkIndex)"))
            }
            
            offset += Int64(chunkData.count)
            chunkIndex += 1
            progressHandler?(Double(offset) / Double(fileSize))
        }
        
        // 3. Assemble chunks via MOVE
        guard let baseURL = config.webDavBaseURL else {
            throw WebDAVError.invalidConfig
        }
        let destinationURL = buildURL(baseURL: baseURL, relativePath: remoteRelativePath)

        // L'en-tête Destination doit être une URI absolue (RFC 4918)
        let moveSourceURL = uploadsURL.appendingPathComponent(".file")
        var moveReq = makeRequest(url: moveSourceURL, method: "MOVE")
        moveReq.setValue(destinationURL.absoluteString, forHTTPHeaderField: "Destination")
        
        let (_, moveResp) = try await session.data(for: moveReq)
        if let http = moveResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WebDAVError.httpError(statusCode: http.statusCode, message: String(localized: "Échec de l'assemblage des morceaux sur Nextcloud"))
        }
    }
    
    // MARK: - DELETE Remote File
    public func deleteFile(remoteRelativePath: String) async throws {
        guard let baseURL = config.webDavBaseURL else {
            throw WebDAVError.invalidConfig
        }
        
        let targetURL = buildURL(baseURL: baseURL, relativePath: remoteRelativePath)
        let request = makeRequest(url: targetURL, method: "DELETE")
        
        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    return
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw WebDAVError.httpError(statusCode: httpResponse.statusCode, message: String(localized: "Échec de suppression du fichier distant: \(remoteRelativePath)"))
                }
            }
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }
}
