//
//  iCloudPhoto2NextcloudApp.swift
//  iCloudPhoto2Nextcloud
//
//  Created by Alexandre de Lemeny-Makedone on 04/08/2026.
//

import SwiftUI
import SwiftData

@main
struct iCloudPhoto2NextcloudApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
