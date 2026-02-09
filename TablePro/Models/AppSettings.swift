//
//  AppSettings.swift
//  TablePro
//
//  Application settings models - pure data structures
//

import AppKit
import Foundation
import SwiftUI

// MARK: - General Settings

/// Startup behavior when app launches
enum StartupBehavior: String, Codable, CaseIterable, Identifiable {
    case showWelcome = "showWelcome"
    case reopenLast = "reopenLast"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .showWelcome: return "Show Welcome Screen"
        case .reopenLast: return "Reopen Last Session"
        }
    }
}

/// General app settings
struct GeneralSettings: Codable, Equatable {
    var startupBehavior: StartupBehavior
    var automaticallyCheckForUpdates: Bool
    var iCloudSyncEnabled: Bool

    static let `default` = GeneralSettings(
        startupBehavior: .showWelcome,
        automaticallyCheckForUpdates: true,
        iCloudSyncEnabled: false
    )

    init(
        startupBehavior: StartupBehavior = .showWelcome,
        automaticallyCheckForUpdates: Bool = true,
        iCloudSyncEnabled: Bool = false
    ) {
        self.startupBehavior = startupBehavior
        self.automaticallyCheckForUpdates = automaticallyCheckForUpdates
        self.iCloudSyncEnabled = iCloudSyncEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startupBehavior = try container.decode(StartupBehavior.self, forKey: .startupBehavior)
        automaticallyCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyCheckForUpdates) ?? true
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? false
    }
}

// MARK: - Appearance Settings

/// App theme options
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Apply this theme to the app
    func apply() {
        switch self {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Accent color options
enum AccentColorOption: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case blue = "blue"
    case purple = "purple"
    case pink = "pink"
    case red = "red"
    case orange = "orange"
    case yellow = "yellow"
    case green = "green"
    case graphite = "graphite"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        default: return rawValue.capitalized
        }
    }

    /// Color for display in settings picker (always returns a concrete color)
    var color: Color {
        switch self {
        case .system: return .accentColor
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .graphite: return .gray
        }
    }

    /// Tint color for applying to views (nil means use system default)
    /// Derived from `color` property for DRY - only .system returns nil
    var tintColor: Color? {
        self == .system ? nil : color
    }
}

/// Appearance settings
struct AppearanceSettings: Codable, Equatable {
    var theme: AppTheme
    var accentColor: AccentColorOption

    static let `default` = AppearanceSettings(
        theme: .system,
        accentColor: .system
    )
}

// MARK: - Editor Settings

/// Available monospace fonts for the SQL editor
enum EditorFont: String, Codable, CaseIterable, Identifiable {
    case systemMono = "System Mono"
    case sfMono = "SF Mono"
    case menlo = "Menlo"
    case monaco = "Monaco"
    case courierNew = "Courier New"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// Get the actual NSFont for this option
    func font(size: CGFloat) -> NSFont {
        switch self {
        case .systemMono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .sfMono:
            return NSFont(name: "SFMono-Regular", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo:
            return NSFont(name: "Menlo", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .monaco:
            return NSFont(name: "Monaco", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .courierNew:
            return NSFont(name: "Courier New", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// Check if this font is available on the system
    var isAvailable: Bool {
        switch self {
        case .systemMono:
            return true
        case .sfMono:
            return NSFont(name: "SFMono-Regular", size: 12) != nil
        case .menlo:
            return NSFont(name: "Menlo", size: 12) != nil
        case .monaco:
            return NSFont(name: "Monaco", size: 12) != nil
        case .courierNew:
            return NSFont(name: "Courier New", size: 12) != nil
        }
    }
}

/// Editor settings
struct EditorSettings: Codable, Equatable {
    var fontFamily: EditorFont
    var fontSize: Int // 11-18pt
    var showLineNumbers: Bool
    var highlightCurrentLine: Bool
    var tabWidth: Int // 2, 4, or 8 spaces
    var autoIndent: Bool
    var wordWrap: Bool

    static let `default` = EditorSettings(
        fontFamily: .systemMono,
        fontSize: 13,
        showLineNumbers: true,
        highlightCurrentLine: true,
        tabWidth: 4,
        autoIndent: true,
        wordWrap: false
    )

    /// Clamped font size (11-18)
    var clampedFontSize: Int {
        min(max(fontSize, 11), 18)
    }

    /// Clamped tab width (1-16)
    var clampedTabWidth: Int {
        min(max(tabWidth, 1), 16)
    }
}

// MARK: - Data Grid Settings

/// Row height options for data grid
enum DataGridRowHeight: Int, Codable, CaseIterable, Identifiable {
    case compact = 20
    case normal = 24
    case comfortable = 28
    case spacious = 32

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .normal: return "Normal"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }
}

/// Date format options
enum DateFormatOption: String, Codable, CaseIterable, Identifiable {
    case iso8601 = "yyyy-MM-dd HH:mm:ss"
    case iso8601Date = "yyyy-MM-dd"
    case usLong = "MM/dd/yyyy hh:mm:ss a"
    case usShort = "MM/dd/yyyy"
    case euLong = "dd/MM/yyyy HH:mm:ss"
    case euShort = "dd/MM/yyyy"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iso8601: return "ISO 8601 (2024-12-31 23:59:59)"
        case .iso8601Date: return "ISO Date (2024-12-31)"
        case .usLong: return "US Long (12/31/2024 11:59:59 PM)"
        case .usShort: return "US Short (12/31/2024)"
        case .euLong: return "EU Long (31/12/2024 23:59:59)"
        case .euShort: return "EU Short (31/12/2024)"
        }
    }

    var formatString: String { rawValue }
}

/// Data grid settings
struct DataGridSettings: Codable, Equatable {
    var rowHeight: DataGridRowHeight
    var dateFormat: DateFormatOption
    var nullDisplay: String
    var defaultPageSize: Int
    var showAlternateRows: Bool

    static let `default` = DataGridSettings(
        rowHeight: .normal,
        dateFormat: .iso8601,
        nullDisplay: "NULL",
        defaultPageSize: 1_000,
        showAlternateRows: true
    )

    // MARK: - Validated Properties

    /// Validated and sanitized nullDisplay (max 20 chars, no newlines)
    var validatedNullDisplay: String {
        let sanitized = nullDisplay.sanitized
        let maxLength = SettingsValidationRules.nullDisplayMaxLength

        // Clamp to max length
        if sanitized.isEmpty {
            return "NULL" // Fallback to default
        } else if sanitized.count > maxLength {
            return String(sanitized.prefix(maxLength))
        }
        return sanitized
    }

    /// Validated defaultPageSize (10 to 100,000)
    var validatedDefaultPageSize: Int {
        defaultPageSize.clamped(to: SettingsValidationRules.defaultPageSizeRange)
    }

    /// Validation error for nullDisplay (for UI feedback)
    var nullDisplayValidationError: String? {
        let sanitized = nullDisplay.sanitized
        let maxLength = SettingsValidationRules.nullDisplayMaxLength

        if sanitized.isEmpty {
            return "NULL display cannot be empty"
        } else if sanitized.count > maxLength {
            return "NULL display must be \(maxLength) characters or less"
        } else if nullDisplay != sanitized {
            return "NULL display contains invalid characters (newlines/tabs)"
        }
        return nil
    }

    /// Validation error for defaultPageSize (for UI feedback)
    var defaultPageSizeValidationError: String? {
        let range = SettingsValidationRules.defaultPageSizeRange
        if defaultPageSize < range.lowerBound || defaultPageSize > range.upperBound {
            return "Page size must be between \(range.lowerBound.formatted()) and \(range.upperBound.formatted())"
        }
        return nil
    }
}

// MARK: - History Settings

/// History settings
struct HistorySettings: Codable, Equatable {
    var maxEntries: Int // 0 = unlimited
    var maxDays: Int // 0 = unlimited
    var autoCleanup: Bool

    static let `default` = HistorySettings(
        maxEntries: 10_000,
        maxDays: 90,
        autoCleanup: true
    )

    // MARK: - Validated Properties

    /// Validated maxEntries (>= 0)
    var validatedMaxEntries: Int {
        max(0, maxEntries)
    }

    /// Validated maxDays (>= 0)
    var validatedMaxDays: Int {
        max(0, maxDays)
    }

    /// Validation error for maxEntries
    var maxEntriesValidationError: String? {
        if maxEntries < 0 {
            return "Maximum entries cannot be negative"
        }
        return nil
    }

    /// Validation error for maxDays
    var maxDaysValidationError: String? {
        if maxDays < 0 {
            return "Maximum days cannot be negative"
        }
        return nil
    }
}
