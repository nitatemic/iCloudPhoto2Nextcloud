//
//  Item.swift
//  iCloudPhoto2Nextcloud
//
//  Created by Alexandre de Lemeny-Makedone on 04/08/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
