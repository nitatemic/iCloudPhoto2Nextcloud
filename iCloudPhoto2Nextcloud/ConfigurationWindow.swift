//
//  ConfigurationWindow.swift
//  iCloudPhoto2Nextcloud
//

import SwiftUI

public struct ConfigurationWindow: View {
    public init() {}
    
    public var body: some View {
        TabView {
            SettingsView()
                .tabItem {
                    Label("Nextcloud", systemImage: "server.rack")
                }
            
            LogAndStatsView()
                .tabItem {
                    Label("Logs & Stats", systemImage: "chart.bar.doc.horizontal")
                }
        }
        .frame(minWidth: 550, minHeight: 400)
    }
}
