//
//  ProFeature.swift
//  TablePro
//
//  Pro feature definitions and access control types
//

import Foundation

/// Features that require a Pro (active) license
enum ProFeature: String, CaseIterable {
    case iCloudSync

    var displayName: String {
        switch self {
        case .iCloudSync:
            return String(localized: "iCloud Sync")
        }
    }

    var systemImage: String {
        switch self {
        case .iCloudSync:
            return "icloud"
        }
    }

    var featureDescription: String {
        switch self {
        case .iCloudSync:
            return String(localized: "Sync connections, settings, and history across your Macs.")
        }
    }
}

/// Result of checking Pro feature availability
enum ProFeatureAccess {
    case available
    case unlicensed
    case expired
}
