//
//  SyncConflict.swift
//  TablePro
//
//  Models for sync conflict detection and resolution.
//

import Foundation

/// Represents a sync conflict between local and remote data
struct SyncConflict: Identifiable {
    let id = UUID()
    let syncKey: String
    let dataType: SyncDataType
    let remoteTimestamp: Date
    let remoteDeviceName: String
    let remoteData: Data

    /// Human-readable summary for the conflict UI
    var summary: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let remoteTime = formatter.localizedString(for: remoteTimestamp, relativeTo: Date())

        return "Local: Modified on this Mac\nRemote: Modified \(remoteTime) on \(remoteDeviceName)"
    }
}

/// User's choice for resolving a conflict
enum ConflictResolution {
    case keepLocal
    case keepRemote
}
