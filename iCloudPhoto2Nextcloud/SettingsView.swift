//
//  SettingsView.swift
//  iCloudPhoto2Nextcloud
//

import SwiftUI
import ServiceManagement
import AppKit

public struct SettingsView: View {
    @Bindable var engine = SyncEngine.shared
    
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var appPassword: String = ""
    @State private var targetFolder: String = "Photos/iCloud"
    @State private var deleteRemote: Bool = true
    @State private var autoVerify: Bool = false
    @State private var verifyIntervalDays: Int = 7
    
    @State private var isTestingConnection = false
    @State private var testResult: ConnectionTestResult?
    @State private var isVerifying = false
    
    /// Flux de connexion via navigateur (sans mot de passe d'application saisi à la main).
    @State private var isLoginFlowActive = false
    @State private var loginFlowMessage: String?
    @State private var loginFlowTask: Task<Void, Never>?
    
    @State private var launchAtLogin: Bool = false
    @State private var checkUpdatesOnLaunch: Bool = true
    /// True une fois la config chargée : évite d'appliquer les réglages pendant le chargement.
    @State private var didLoadConfig = false
    /// Tâche de sauvegarde différée pour les champs texte (évite de sauvegarder à chaque frappe).
    @State private var saveTask: Task<Void, Never>?
    
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
                    .onChange(of: serverURL) { scheduleSave() }
                
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
                    .onChange(of: username) { scheduleSave() }
                
                SecureField("Mot de passe d'application (App Password)", text: $appPassword)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: appPassword) { scheduleSave() }
                
                Divider()
                    .padding(.vertical, 4)
                
                HStack {
                    Button(action: startBrowserLogin) {
                        if isLoginFlowActive {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Connexion en cours...")
                            }
                        } else {
                            Label("Se connecter via le navigateur", systemImage: "person.badge.key")
                        }
                    }
                    .disabled(isLoginFlowActive || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    if isLoginFlowActive {
                        Button("Annuler") {
                            loginFlowTask?.cancel()
                        }
                    }
                }
                
                if let message = loginFlowMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
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
                    .onChange(of: targetFolder) { scheduleSave() }
                
                Toggle("Supprimer sur Nextcloud si supprimé localement (Miroir exact)", isOn: $deleteRemote)
                    .toggleStyle(.checkbox)
                    .onChange(of: deleteRemote) { applySettings() }
            }
            
            Section("Vérification de la sauvegarde") {
                Toggle("Vérifier automatiquement l'intégrité de la sauvegarde", isOn: $autoVerify)
                    .toggleStyle(.checkbox)
                    .help("Liste périodiquement les fichiers sur Nextcloud et renvoie ceux qui auraient disparu ou seraient corrompus (long sur les grosses bibliothèques).")
                    .onChange(of: autoVerify) { applySettings() }
                
                Picker("Fréquence", selection: $verifyIntervalDays) {
                    Text("Tous les jours").tag(1)
                    Text("Chaque semaine").tag(7)
                    Text("Chaque mois").tag(30)
                }
                .disabled(!autoVerify)
                .onChange(of: verifyIntervalDays) { applySettings() }
                
                HStack {
                    Button(action: verifyNow) {
                        if isVerifying {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Vérification en cours...")
                            }
                        } else {
                            Text("Vérifier maintenant")
                        }
                    }
                    .disabled(isSyncing || isVerifying || !engine.config.isValid)
                    
                    if let last = engine.lastVerificationDate {
                        Text("Dernière vérification : \(last.formatted(date: .numeric, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if isSyncing {
                    Text("Vérification indisponible pendant une synchronisation en cours.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Section("Général") {
                Toggle("Lancer au démarrage de la session", isOn: launchAtLoginBinding)
                    .toggleStyle(.checkbox)
                    .help("Démarre l'agent en arrière-plan à l'ouverture de session (nécessite l'application dans /Applications).")
                
                Toggle("Vérifier les mises à jour au lancement", isOn: $checkUpdatesOnLaunch)
                    .toggleStyle(.checkbox)
                    .onChange(of: checkUpdatesOnLaunch) {
                        UserDefaults.standard.set(checkUpdatesOnLaunch, forKey: AppUpdater.checkOnLaunchKey)
                    }
            }
        }
        .padding(20)
        .onAppear {
            loadCurrentConfig()
        }
        .onDisappear {
            applySettings()
        }
    }
    
    /// Lit l'état réel de l'inscription en login item et applique le changement immédiatement.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = newValue
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                    engine.log(String(localized: "Échec de la configuration du lancement au démarrage: \(error.localizedDescription)"), level: .error)
                }
            }
        )
    }
    
    private func loadCurrentConfig() {
        let current = engine.config
        self.serverURL = current.serverURL
        self.username = current.username
        self.appPassword = current.appPassword
        self.targetFolder = current.targetFolder
        self.deleteRemote = current.deleteRemoteOnLocalDelete
        self.autoVerify = current.autoVerifyEnabled
        self.verifyIntervalDays = current.verifyIntervalDays
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.checkUpdatesOnLaunch = UserDefaults.standard.object(forKey: AppUpdater.checkOnLaunchKey) as? Bool ?? true
        self.didLoadConfig = true
    }
    
    private var isSyncing: Bool {
        // Une synchronisation en pause reste une synchronisation en cours.
        switch engine.state {
        case .syncing, .paused:
            return true
        default:
            return false
        }
    }
    
    private func verifyNow() {
        isVerifying = true
        engine.performIntegrityVerification()
        // Le scan tourne en arrière-plan (état .verifying) : on rétablit le bouton au prochain tick.
        Task {
            while isVerifying {
                try? await Task.sleep(for: .seconds(1))
                if case .verifying = engine.state {
                    continue
                }
                isVerifying = false
                return
            }
        }
    }
    
    /// Applique immédiatement les réglages courants (champs texte inclus) au moteur.
    private func applySettings() {
        guard didLoadConfig else { return }
        
        var normalizedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedURL.isEmpty && !normalizedURL.lowercased().hasPrefix("http://") && !normalizedURL.lowercased().hasPrefix("https://") {
            normalizedURL = "https://" + normalizedURL
            if normalizedURL != serverURL {
                self.serverURL = normalizedURL
            }
        }
        
        let newConfig = NextcloudConfig(
            serverURL: normalizedURL,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            appPassword: appPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            targetFolder: targetFolder.trimmingCharacters(in: .whitespacesAndNewlines),
            deleteRemoteOnLocalDelete: deleteRemote,
            autoVerifyEnabled: autoVerify,
            verifyIntervalDays: verifyIntervalDays
        )
        
        // Les réglages secondaires (miroir, vérification, fréquence) ne nécessitent pas de nouveau scan :
        // un scan complet n'est lancé que si la connexion ou le dossier distant ont changé.
        let connectionChanged = newConfig.serverURL != engine.config.serverURL
            || newConfig.username != engine.config.username
            || newConfig.appPassword != engine.config.appPassword
            || newConfig.targetFolder != engine.config.targetFolder
        
        newConfig.saveToKeychain()
        engine.config = newConfig
        engine.log(String(localized: "Configuration Nextcloud sauvegardée."), level: .info)
        
        if connectionChanged {
            if newConfig.isValid {
                engine.performFullScan()
            } else {
                engine.log(String(localized: "La configuration Nextcloud est incomplète."), level: .warning)
            }
        }
    }
    
    /// Sauvegarde différée (0,6 s) : évite d'appliquer les réglages à chaque frappe pendant la saisie.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            applySettings()
        }
    }
    
    /// Lance le flux de connexion officiel de Nextcloud : ouvre le navigateur où
    /// l'utilisateur s'authentifie et autorise l'appareil, puis récupère le mot de
    /// passe d'application généré (aucune saisie manuelle nécessaire).
    private func startBrowserLogin() {
        var normalizedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedURL.isEmpty && !normalizedURL.lowercased().hasPrefix("http://") && !normalizedURL.lowercased().hasPrefix("https://") {
            normalizedURL = "https://" + normalizedURL
            self.serverURL = normalizedURL
        }
        guard NextcloudLoginFlow.normalizedBaseURL(from: normalizedURL) != nil else {
            loginFlowMessage = String(localized: "URL du serveur Nextcloud invalide.")
            return
        }
        
        isLoginFlowActive = true
        loginFlowMessage = nil
        testResult = nil
        engine.log(String(localized: "Démarrage du flux de connexion via navigateur vers \(normalizedURL)..."), level: .info)
        
        let task = Task {
            do {
                let session = try await NextcloudLoginFlow.start(serverURL: normalizedURL)
                self.loginFlowMessage = String(localized: "Ouverture du navigateur : connectez-vous puis autorisez cet appareil.")
                guard NSWorkspace.shared.open(session.loginURL) else {
                    throw LoginFlowError.browserFailed
                }
                self.loginFlowMessage = String(localized: "En attente d'autorisation dans le navigateur...")
                let credentials = try await NextcloudLoginFlow.poll(session: session)
                
                self.serverURL = credentials.serverURL.isEmpty ? self.serverURL : credentials.serverURL
                self.username = credentials.loginName
                self.appPassword = credentials.appPassword
                applySettings()
                self.loginFlowMessage = String(localized: "Connexion réussie : appareil ajouté dans Nextcloud.")
                engine.log(String(localized: "Connexion via navigateur réussie pour \(credentials.loginName)."), level: .success)
                testConnection()
            } catch is CancellationError {
                self.loginFlowMessage = String(localized: "Connexion annulée.")
                engine.log(String(localized: "Flux de connexion annulé par l'utilisateur."), level: .info)
            } catch {
                self.loginFlowMessage = error.localizedDescription
                engine.log(String(localized: "Échec du flux de connexion : \(error.localizedDescription)"), level: .error)
            }
            self.isLoginFlowActive = false
        }
        loginFlowTask = task
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
