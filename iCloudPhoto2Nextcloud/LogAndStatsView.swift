//
//  LogAndStatsView.swift
//  iCloudPhoto2Nextcloud
//

import SwiftUI

public struct LogAndStatsView: View {
    @Bindable var engine = SyncEngine.shared
    @State private var searchText = ""
    @State private var selectedLevelFilter: String = "ALL"
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Stats summary card
            HStack(spacing: 16) {
                statCard(title: "Photothèque", count: "\(engine.totalAssets)", icon: "photo.stack", color: .blue)
                statCard(title: "Synchronisés", count: "\(engine.syncedAssetsCount)", icon: "checkmark.seal.fill", color: .green)
                statCard(title: "En attente", count: "\(engine.pendingAssetsCount)", icon: "clock.fill", color: .orange)
            }
            
            Divider()
            
            // Search and filter toolbar
            HStack {
                TextField("Rechercher dans les logs...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                
                Picker("Filtre", selection: $selectedLevelFilter) {
                    Text("Tous").tag("ALL")
                    Text("Info").tag("INFO")
                    Text("Succès").tag("SUCCESS")
                    Text("Erreurs").tag("ERROR")
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                
                Button("Effacer les logs") {
                    engine.clearLogs()
                }
                .disabled(engine.recentLogs.isEmpty)
            }
            
            // Log entries list
            List(filteredLogs) { log in
                HStack(alignment: .top, spacing: 10) {
                    levelBadge(log.level)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.message)
                            .font(.system(.body, design: .monospaced))
                        Text(log.timestamp.formatted(date: .numeric, time: .standard))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .cornerRadius(6)
        }
        .padding(16)
    }
    
    private var filteredLogs: [SyncLogEntry] {
        engine.recentLogs.filter { entry in
            let matchesSearch = searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText)
            let matchesFilter = (selectedLevelFilter == "ALL") || (entry.level.rawValue == selectedLevelFilter)
            return matchesSearch && matchesFilter
        }
    }
    
    private func statCard(title: String, count: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(count)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(count)")
    }
    
    @ViewBuilder
    private func levelBadge(_ level: SyncLogEntry.LogLevel) -> some View {
        switch level {
        case .info:
            Text("INFO")
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.2))
                .foregroundColor(.blue)
                .cornerRadius(4)
        case .success:
            Text("OK")
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.2))
                .foregroundColor(.green)
                .cornerRadius(4)
        case .warning:
            Text("WARN")
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.2))
                .foregroundColor(.orange)
                .cornerRadius(4)
        case .error:
            Text("ERR")
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.2))
                .foregroundColor(.red)
                .cornerRadius(4)
        }
    }
}
