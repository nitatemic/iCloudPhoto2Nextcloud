//
//  SettingsView.swift
//  iCloudPhoto2Nextcloud
//

import SwiftUI

public struct SettingsView: View {
    @Bindable var engine = SyncEngine.shared
    
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var appPassword: String = ""
    @State private var targetFolder: String = "Photos/iCloud"
    @State private var deleteRemote: Bool = true
    
    @State private var isTestingConnection = false
    @State private var testResult: ConnectionTestResult?
    
    private enum ConnectionTestResult {
        case success
        case failure(String)
    }
    
    public init() {}
    
    public var body: some View {
        Form {
            Section("Connexion Serveur Nextcloud") {
                TextField("URL du serveur (ex: https://cloud.exemple.dev)", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                
                if serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(.orange)
                        Text("Connexion HTTP non sécurisée : Vos identifiants voyagent en clair.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .padding(.vertical, 2)
                }
                
                TextField("Nom d'utilisateur", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                
                SecureField("Mot de passe d'application (App Password)", text: $appPassword)
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Button(action: testConnection) {
                        if isTestingConnection {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Test en cours...")
                            }
                        } else {
                            Text("Tester la connexion")
                        }
                    }
                    .disabled(isTestingConnection || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    if let result = testResult {
                        switch result {
                        case .success:
                            Label("Connexion réussie", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.subheadline)
                        case .failure(let error):
                            Label(error, systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.top, 4)
            }
            
            Section("Options de Synchronisation") {
                TextField("Dossier distant sur Nextcloud", text: $targetFolder)
                    .textFieldStyle(.roundedBorder)
                
                Toggle("Supprimer sur Nextcloud si supprimé localement (Miroir exact)", isOn: $deleteRemote)
                    .toggleStyle(.checkbox)
            }
            
            Section {
                HStack {
                    Spacer()
                    Button("Enregistrer les réglages") {
                        saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .onAppear {
            loadCurrentConfig()
        }
    }
    
    private func loadCurrentConfig() {
        let current = engine.config
        self.serverURL = current.serverURL
        self.username = current.username
        self.appPassword = current.appPassword
        self.targetFolder = current.targetFolder
        self.deleteRemote = current.deleteRemoteOnLocalDelete
    }
    
    private func saveSettings() {
        var normalizedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedURL.isEmpty && !normalizedURL.lowercased().hasPrefix("http://") && !normalizedURL.lowercased().hasPrefix("https://") {
            normalizedURL = "https://" + normalizedURL
            self.serverURL = normalizedURL
        }
        
        let newConfig = NextcloudConfig(
            serverURL: normalizedURL,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            appPassword: appPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            targetFolder: targetFolder.trimmingCharacters(in: .whitespacesAndNewlines),
            deleteRemoteOnLocalDelete: deleteRemote
        )
        newConfig.saveToKeychain()
        engine.config = newConfig
        engine.log(String(localized: "Configuration Nextcloud sauvegardée."), level: .info)
        
        if newConfig.isValid {
            engine.performFullScan()
        } else {
            engine.log(String(localized: "La configuration Nextcloud est incomplète."), level: .warning)
        }
    }
    
    private func testConnection() {
        isTestingConnection = true
        testResult = nil
        
        var normalizedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedURL.isEmpty && !normalizedURL.lowercased().hasPrefix("http://") && !normalizedURL.lowercased().hasPrefix("https://") {
            normalizedURL = "https://" + normalizedURL
            self.serverURL = normalizedURL
        }
        
        let tempConfig = NextcloudConfig(
            serverURL: normalizedURL,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            appPassword: appPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            targetFolder: targetFolder.trimmingCharacters(in: .whitespacesAndNewlines),
            deleteRemoteOnLocalDelete: deleteRemote
        )
        
        engine.log(String(localized: "Lancement du test de connexion vers \(normalizedURL)..."), level: .info)
        
        Task {
            let service = NextcloudWebDAVService(config: tempConfig)
            do {
                let success = try await service.testConnection()
                if success {
                    self.testResult = .success
                    engine.log(String(localized: "Succès : Connexion WebDAV à Nextcloud établie avec succès !"), level: .success)
                } else {
                    self.testResult = .failure(String(localized: "Le serveur n'a pas répondu favorablement au WebDAV."))
                    engine.log(String(localized: "Échec : Le serveur Nextcloud n'a pas validé la requête WebDAV PROPFIND."), level: .error)
                }
            } catch {
                self.testResult = .failure(error.localizedDescription)
                engine.log(String(localized: "Erreur de test de connexion : \(error.localizedDescription)"), level: .error)
            }
            self.isTestingConnection = false
        }
    }
}
