//
//  SyncError.swift
//  TablePro
//
//  Sync-specific error types
//

import Foundation

/// Errors that can occur during sync operations
enum SyncError: LocalizedError, Equatable {
    case networkUnavailable
    case accountUnavailable
    case quotaExceeded
    case zoneNotFound
    case serverError(String)
    case conflictDetected
    case encodingFailed(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return String(localized: "Network is unavailable. Changes will sync when connectivity is restored.")
        case .accountUnavailable:
            return String(localized: "iCloud account is not available. Sign in to iCloud in System Settings.")
        case .quotaExceeded:
            return String(localized: "iCloud storage is full. Free up space or reduce the history sync limit.")
        case .zoneNotFound:
            return String(localized: "Sync zone not found. A full sync will be performed.")
        case .serverError(let message):
            return String(localized: "iCloud server error: \(message)")
        case .conflictDetected:
            return String(localized: "A sync conflict was detected and needs to be resolved.")
        case .encodingFailed(let detail):
            return String(localized: "Failed to encode sync data: \(detail)")
        case .unknown(let message):
            return String(localized: "An unknown sync error occurred: \(message)")
        }
    }

    /// Convert a generic Error into a SyncError
    static func from(_ error: Error) -> SyncError {
        if let syncError = error as? SyncError {
            return syncError
        }

        // Map CKError codes to SyncError
        let nsError = error as NSError
        if nsError.domain == "CKErrorDomain" {
            switch nsError.code {
            case 3, 36: // networkUnavailable, networkFailure
                return .networkUnavailable
            case 9: // notAuthenticated
                return .accountUnavailable
            case 25: // quotaExceeded
                return .quotaExceeded
            case 26: // zoneNotFound
                return .zoneNotFound
            default:
                return .serverError(nsError.localizedDescription)
            }
        }

        return .unknown(error.localizedDescription)
    }

    static func == (lhs: SyncError, rhs: SyncError) -> Bool {
        switch (lhs, rhs) {
        case (.networkUnavailable, .networkUnavailable),
             (.accountUnavailable, .accountUnavailable),
             (.quotaExceeded, .quotaExceeded),
             (.zoneNotFound, .zoneNotFound),
             (.conflictDetected, .conflictDetected):
            return true
        case (.serverError(let a), .serverError(let b)):
            return a == b
        case (.encodingFailed(let a), .encodingFailed(let b)):
            return a == b
        case (.unknown(let a), .unknown(let b)):
            return a == b
        default:
            return false
        }
    }
}
