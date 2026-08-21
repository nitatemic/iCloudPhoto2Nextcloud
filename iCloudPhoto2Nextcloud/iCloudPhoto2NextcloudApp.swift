//
//  iCloudPhoto2NextcloudApp.swift
//  iCloudPhoto2Nextcloud
//

import SwiftUI
import SwiftData

@main
struct iCloudPhoto2NextcloudApp: App {
    @State private var engine = SyncEngine.shared
    
    init() {
        // Start background Sync Engine
        SyncEngine.shared.startEngine()
        // Vérifier la connexion au démarrage (async, non-bloquant)
        Task { await SyncEngine.shared.checkConnectionAtStartup() }
    }
    
    var body: some Scene {
        // MenuBarExtra scene (Status Bar Icon + Popover)
        MenuBarExtra {
            StatusMenuView()
        } label: {
            let iconName = menuBarIconName(for: engine.state)
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)
        
        // Detachable Configuration & Logs Window
        Window("Réglages iCloudPhoto2Nextcloud", id: "settingsWindow") {
            ConfigurationWindow()
        }
        .windowResizability(.contentSize)
    }
    
    private func menuBarIconName(for state: EngineState) -> String {
        switch state {
        case .idle:
            return "photo.badge.checkmark"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .paused:
            return "pause.circle"
        case .verifying:
            return "checkmark.shield"
        case .unauthorized, .error:
            return "exclamationmark.triangle"
        }
    }
}
