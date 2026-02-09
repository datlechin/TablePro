//
//  SyncEngine.swift
//  TablePro
//
//  Protocol defining a sync backend for iCloud or other services.
//

import Foundation

// MARK: - Sync Engine Protocol

/// Protocol for sync backends (NSUbiquitousKeyValueStore, CloudKit, etc.)
protocol SyncEngine {
    /// Whether the sync backend is available (e.g., iCloud signed in)
    var isAvailable: Bool { get }

    /// Start observing remote changes
    func startObserving(onChange: @escaping ([String]) -> Void)

    /// Stop observing remote changes
    func stopObserving()

    /// Write data for a key
    func write(_ data: Data, forKey key: String)

    /// Read data for a key
    func read(forKey key: String) -> Data?

    /// Remove data for a key
    func remove(forKey key: String)

    /// Force synchronization with remote
    @discardableResult
    func synchronize() -> Bool
}

// MARK: - Sync Envelope

/// Wrapper for synced data with metadata for conflict detection
struct SyncEnvelope: Codable {
    let payload: Data
    let modifiedAt: Date
    let deviceId: String
    let deviceName: String
}

// MARK: - Sync Data Type

/// Types of data that can be synced
enum SyncDataType: String, CaseIterable {
    case connections = "Connections"
    case tags = "Tags"
    case generalSettings = "General Settings"
    case appearanceSettings = "Appearance Settings"
    case editorSettings = "Editor Settings"
    case dataGridSettings = "Data Grid Settings"
    case historySettings = "History Settings"
    case templates = "Templates"
}

// MARK: - Sync Error

/// Errors that can occur during sync
enum SyncError: LocalizedError {
    case iCloudUnavailable
    case encodingFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud is not available. Please sign in to iCloud in System Settings."
        case .encodingFailed(let detail):
            return "Failed to encode sync data: \(detail)"
        case .decodingFailed(let detail):
            return "Failed to decode sync data: \(detail)"
        }
    }
}
