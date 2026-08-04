//
//  NextcloudConfig.swift
//  iCloudPhoto2Nextcloud
//

import Foundation

public struct NextcloudConfig: Sendable, Equatable {
    public var serverURL: String
    public var username: String
    public var appPassword: String
    public var targetFolder: String
    public var deleteRemoteOnLocalDelete: Bool
    
    public init(
        serverURL: String = "",
        username: String = "",
        appPassword: String = "",
        targetFolder: String = "Photos/iCloud",
        deleteRemoteOnLocalDelete: Bool = true
    ) {
        self.serverURL = serverURL
        self.username = username
        self.appPassword = appPassword
        self.targetFolder = targetFolder
        self.deleteRemoteOnLocalDelete = deleteRemoteOnLocalDelete
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
        
        let pathComponent = "/remote.php/dav/files/\(username.trimmingCharacters(in: .whitespacesAndNewlines))"
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
    
    public static func loadFromKeychain() -> NextcloudConfig {
        let defaults = UserDefaults.standard
        let url = defaults.string(forKey: serverURLKey) ?? ""
        let user = defaults.string(forKey: usernameKey) ?? ""
        let pass = KeychainManager.shared.getString(key: passwordKeychainKey) ?? ""
        let folder = defaults.string(forKey: targetFolderKey) ?? "Photos/iCloud"
        let deleteRemote = defaults.object(forKey: deleteRemoteKey) as? Bool ?? true
        
        return NextcloudConfig(
            serverURL: url,
            username: user,
            appPassword: pass,
            targetFolder: folder,
            deleteRemoteOnLocalDelete: deleteRemote
        )
    }
    
    public func saveToKeychain() {
        let defaults = UserDefaults.standard
        defaults.set(serverURL, forKey: Self.serverURLKey)
        defaults.set(username, forKey: Self.usernameKey)
        defaults.set(targetFolder, forKey: Self.targetFolderKey)
        defaults.set(deleteRemoteOnLocalDelete, forKey: Self.deleteRemoteKey)
        
        _ = KeychainManager.shared.save(key: Self.passwordKeychainKey, string: appPassword)
    }
}
