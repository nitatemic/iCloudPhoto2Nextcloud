//
//  NextcloudConfig.swift
//  iCloudPhoto2Nextcloud
//

import Foundation

public nonisolated struct NextcloudConfig: Sendable, Equatable {
    public var serverURL: String
    public var username: String
    public var appPassword: String
    public var targetFolder: String
    public var deleteRemoteOnLocalDelete: Bool
    /// Vérification périodique de l'intégrité de la sauvegarde sur Nextcloud.
    public var autoVerifyEnabled: Bool
    /// Intervalle (en jours) entre deux vérifications automatiques.
    public var verifyIntervalDays: Int
    
    public init(
        serverURL: String = "",
        username: String = "",
        appPassword: String = "",
        targetFolder: String = "Photos/iCloud",
        deleteRemoteOnLocalDelete: Bool = true,
        autoVerifyEnabled: Bool = false,
        verifyIntervalDays: Int = 7
    ) {
        self.serverURL = serverURL
        self.username = username
        self.appPassword = appPassword
        self.targetFolder = targetFolder
        self.deleteRemoteOnLocalDelete = deleteRemoteOnLocalDelete
        self.autoVerifyEnabled = autoVerifyEnabled
        self.verifyIntervalDays = verifyIntervalDays
    }
    
    public var isValid: Bool {
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            base = "https://" + base
        }
        guard let url = URL(string: base),
              let host = url.host, !host.isEmpty,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !appPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return url.scheme == "http" || url.scheme == "https"
    }
    
    /// Normalizes server URL to standard WebDAV base URL (e.g., https://nextcloud.example.com/remote.php/dav/files/USERNAME/)
    public var webDavBaseURL: URL? {
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            base = "https://" + base
        }
        
        while base.hasSuffix("/") {
            base.removeLast()
        }
        
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedUsername = trimmedUsername.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedUsername
        let pathComponent = "/remote.php/dav/files/\(encodedUsername)"
        if !base.hasSuffix(pathComponent) {
            base += pathComponent
        }
        
        if !base.hasSuffix("/") {
            base += "/"
        }
        
        return URL(string: base)
    }
    
    // Key storage helpers
    private static let serverURLKey = "nc_server_url"
    private static let usernameKey = "nc_username"
    private static let passwordKeychainKey = "nc_app_password"
    private static let targetFolderKey = "nc_target_folder"
    private static let deleteRemoteKey = "nc_delete_remote"
    private static let autoVerifyKey = "nc_auto_verify"
    private static let verifyIntervalKey = "nc_verify_interval_days"
    
    public static func loadFromKeychain() -> NextcloudConfig {
        let defaults = UserDefaults.standard
        let url = defaults.string(forKey: serverURLKey) ?? ""
        let user = defaults.string(forKey: usernameKey) ?? ""
        let pass = KeychainManager.shared.getString(key: passwordKeychainKey) ?? ""
        let folder = defaults.string(forKey: targetFolderKey) ?? "Photos/iCloud"
        let deleteRemote = defaults.object(forKey: deleteRemoteKey) as? Bool ?? true
        let autoVerify = defaults.object(forKey: autoVerifyKey) as? Bool ?? false
        let verifyInterval = defaults.object(forKey: verifyIntervalKey) as? Int ?? 7
        
        return NextcloudConfig(
            serverURL: url,
            username: user,
            appPassword: pass,
            targetFolder: folder,
            deleteRemoteOnLocalDelete: deleteRemote,
            autoVerifyEnabled: autoVerify,
            verifyIntervalDays: verifyInterval
        )
    }
    
    public func saveToKeychain() {
        let defaults = UserDefaults.standard
        defaults.set(serverURL, forKey: Self.serverURLKey)
        defaults.set(username, forKey: Self.usernameKey)
        defaults.set(targetFolder, forKey: Self.targetFolderKey)
        defaults.set(deleteRemoteOnLocalDelete, forKey: Self.deleteRemoteKey)
        defaults.set(autoVerifyEnabled, forKey: Self.autoVerifyKey)
        defaults.set(verifyIntervalDays, forKey: Self.verifyIntervalKey)
        
        _ = KeychainManager.shared.save(key: Self.passwordKeychainKey, string: appPassword)
    }
}
