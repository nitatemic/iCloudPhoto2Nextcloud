//
//  SyncLogEntry.swift
//  iCloudPhoto2Nextcloud
//

import Foundation

public struct SyncLogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let message: String
    public let level: LogLevel
    
    public enum LogLevel: String, Sendable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case success = "SUCCESS"
    }
    
    public init(id: UUID = UUID(), timestamp: Date = Date(), message: String, level: LogLevel = .info) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.level = level
    }
}
