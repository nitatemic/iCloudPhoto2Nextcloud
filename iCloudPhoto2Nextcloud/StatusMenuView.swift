//
//  StatusMenuView.swift
//  iCloudPhoto2Nextcloud
//

import SwiftUI

public struct StatusMenuView: View {
    @Bindable var engine = SyncEngine.shared
    @Environment(\.openWindow) private var openWindow
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Status Banner
            headerView
            
            Divider()
            
            // Progress Bar if Syncing or Paused or Verifying
            if case .syncing(let progress, let message) = engine.state {
                progressSection(progress: progress, message: message, isPaused: false)
            } else if case .paused(let progress, let message) = engine.state {
                progressSection(progress: progress, message: message, isPaused: true)
            } else if case .verifying(let progress, let message) = engine.state {
                progressSection(progress: progress, message: message, isPaused: false)
            }
            
            // Stats summary grid
            statsGrid
            
            // Recent synced photos
            if !engine.recentSyncedIDs.isEmpty {
                Divider()
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dernières photos synchronisées")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(engine.recentSyncedIDs, id: \.self) { identifier in
                                PhotoThumbnailView(localIdentifier: identifier, size: CGSize(width: 56, height: 56))
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            // Actions
            VStack(spacing: 4) {
                // Pause / Resume Toggle Button
                if isSyncingOrPaused {
                    menuButton(
                        title: engine.isPaused ? "Reprendre la synchronisation" : "Mettre en pause",
                        icon: engine.isPaused ? "play.fill" : "pause.fill"
                    ) {
                        engine.togglePause()
                    }
                }
                
                // Raccourci vers les réglages de confidentialité quand l'accès Photos est refusé
                if case .unauthorized = engine.state {
                    menuButton(title: "Autoriser l'accès aux photos...", icon: "lock.shield") {
                        openPhotosPrivacySettings()
                    }
                }
                
                menuButton(title: "Forcer un scan complet", icon: "arrow.clockwise", disabled: isSyncing) {
                    engine.performFullScan()
                }
                
                menuButton(title: isVerifying ? "Vérification en cours..." : "Vérifier la sauvegarde", icon: "checkmark.shield", disabled: isVerifying || isSyncing) {
                    engine.performIntegrityVerification()
                }
                
                if isSyncing {
                    Text("Vérification disponible une fois la synchronisation terminée.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
                
                menuButton(title: "Réglages & Logs...", icon: "gearshape") {
                    openSettingsWindow()
                }
                
                menuButton(title: "À propos", icon: "info.circle") {
                    // App LSUIElement (pas d'icône Dock) : AppKit ne charge pas
                    // toujours l'icône du bundle pour le panneau À propos.
                    if NSApp.applicationIconImage == nil {
                        let icon = NSImage(named: "AppIcon") ?? Bundle.main.image(forResource: "AppIcon")
                        if let icon {
                            NSApp.applicationIconImage = icon
                        }
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            
            Divider()
            
            // Footer Quit
            menuButton(title: "Quitter", icon: "power", isDestructive: true) {
                SyncEngine.shared.stopEngine()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 300)
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
    
    private var isVerifying: Bool {
        if case .verifying = engine.state { return true }
        return false
    }
    
    private var isSyncingOrPaused: Bool {
        switch engine.state {
        case .syncing, .paused, .verifying:
            return true
        default:
            return false
        }
    }
    
    private func progressSection(progress: Double, message: String, isPaused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(isPaused ? .orange : .blue)
            
            HStack {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if isPaused {
                    Text("PAUSE")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 2)
    }
    
    private var headerView: some View {
        HStack(spacing: 10) {
            statusIcon
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("iCloud → Nextcloud")
                    .font(.headline)
                
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch engine.state {
        case .idle:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundColor(.blue)
        case .verifying:
            Image(systemName: "checkmark.shield.fill")
                .foregroundColor(.blue)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundColor(.orange)
        case .unauthorized, .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
    }
    
    private var statusSubtitle: String {
        switch engine.state {
        case .idle:
            if let last = engine.lastSyncDate {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                return String(localized: "À jour (\(formatter.localizedString(for: last, relativeTo: Date())))")
            }
            return String(localized: "À jour")
        case .syncing(_, let msg):
            return msg
        case .verifying(_, let msg):
            return msg
        case .paused(_, let msg):
            return msg
        case .unauthorized:
            return "Accès photos non autorisé"
        case .error(let msg):
            return msg
        }
    }
    
    private var statsGrid: some View {
        HStack(spacing: 16) {
            statCell(title: "Total", count: engine.totalAssets, color: .primary)
            statCell(title: "Synchro", count: engine.syncedAssetsCount, color: .green)
            statCell(title: "En attente", count: engine.pendingAssetsCount, color: .orange)
        }
    }
    
    private func statCell(title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .center, spacing: 2) {
            Text("\(count)")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(count)")
    }
    
    private func menuButton(
        title: String,
        icon: String,
        isDestructive: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18, alignment: .center)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle(isDestructive: isDestructive))
        .disabled(disabled)
    }
    
    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settingsWindow")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApp.windows {
                if window.identifier?.rawValue == "settingsWindow" || window.title.contains("Réglages") {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
    }

    private func openPhotosPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct MenuRowButtonStyle: ButtonStyle {
    var isDestructive: Bool = false
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isDestructive ? .red : (configuration.isPressed ? .secondary : .primary))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? (isDestructive ? Color.red.opacity(0.15) : Color.primary.opacity(0.1)) : Color.clear)
            )
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
