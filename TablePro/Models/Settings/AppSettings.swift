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
        case .showWelcome: return String(localized: "Show Welcome Screen")
        case .reopenLast: return String(localized: "Reopen Last Session")
        }
    }
}

/// App language options
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case vietnamese = "vi"
    case chineseSimplified = "zh-Hans"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        case .chineseSimplified: return "简体中文"
        }
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// General app settings
struct GeneralSettings: Codable, Equatable {
    var startupBehavior: StartupBehavior
    var language: AppLanguage
    var automaticallyCheckForUpdates: Bool

    /// Query execution timeout in seconds (0 = no limit)
    var queryTimeoutSeconds: Int

    /// Whether to share anonymous usage analytics
    var shareAnalytics: Bool

    static let `default` = GeneralSettings(
        startupBehavior: .showWelcome,
        language: .system,
        automaticallyCheckForUpdates: true,
        queryTimeoutSeconds: 60,
        shareAnalytics: true
    )

    init(
        startupBehavior: StartupBehavior = .showWelcome,
        language: AppLanguage = .system,
        automaticallyCheckForUpdates: Bool = true,
        queryTimeoutSeconds: Int = 60,
        shareAnalytics: Bool = true
    ) {
        self.startupBehavior = startupBehavior
        self.language = language
        self.automaticallyCheckForUpdates = automaticallyCheckForUpdates
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.shareAnalytics = shareAnalytics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startupBehavior = try container.decode(StartupBehavior.self, forKey: .startupBehavior)
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        automaticallyCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyCheckForUpdates) ?? true
        queryTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .queryTimeoutSeconds) ?? 60
        shareAnalytics = try container.decodeIfPresent(Bool.self, forKey: .shareAnalytics) ?? true
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
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    /// Apply this theme to the app
    func apply() {
        guard let app = NSApp else { return }
        switch self {
        case .system:
            app.appearance = nil
        case .light:
            app.appearance = NSAppearance(named: .aqua)
        case .dark:
            app.appearance = NSAppearance(named: .darkAqua)
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
        case .system: return String(localized: "System")
        case .blue: return String(localized: "Blue")
        case .purple: return String(localized: "Purple")
        case .pink: return String(localized: "Pink")
        case .red: return String(localized: "Red")
        case .orange: return String(localized: "Orange")
        case .yellow: return String(localized: "Yellow")
        case .green: return String(localized: "Green")
        case .graphite: return String(localized: "Graphite")
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
    var vimModeEnabled: Bool

    static let `default` = EditorSettings(
        fontFamily: .systemMono,
        fontSize: 13,
        showLineNumbers: true,
        highlightCurrentLine: true,
        tabWidth: 4,
        autoIndent: true,
        wordWrap: false,
        vimModeEnabled: false
    )

    init(
        fontFamily: EditorFont = .systemMono,
        fontSize: Int = 13,
        showLineNumbers: Bool = true,
        highlightCurrentLine: Bool = true,
        tabWidth: Int = 4,
        autoIndent: Bool = true,
        wordWrap: Bool = false,
        vimModeEnabled: Bool = false
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.showLineNumbers = showLineNumbers
        self.highlightCurrentLine = highlightCurrentLine
        self.tabWidth = tabWidth
        self.autoIndent = autoIndent
        self.wordWrap = wordWrap
        self.vimModeEnabled = vimModeEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try container.decode(EditorFont.self, forKey: .fontFamily)
        fontSize = try container.decode(Int.self, forKey: .fontSize)
        showLineNumbers = try container.decode(Bool.self, forKey: .showLineNumbers)
        highlightCurrentLine = try container.decode(Bool.self, forKey: .highlightCurrentLine)
        tabWidth = try container.decode(Int.self, forKey: .tabWidth)
        autoIndent = try container.decode(Bool.self, forKey: .autoIndent)
        wordWrap = try container.decode(Bool.self, forKey: .wordWrap)
        vimModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .vimModeEnabled) ?? false
    }

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
        case .compact: return String(localized: "Compact")
        case .normal: return String(localized: "Normal")
        case .comfortable: return String(localized: "Comfortable")
        case .spacious: return String(localized: "Spacious")
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
        case .iso8601: return String(localized: "ISO 8601 (2024-12-31 23:59:59)")
        case .iso8601Date: return String(localized: "ISO Date (2024-12-31)")
        case .usLong: return String(localized: "US Long (12/31/2024 11:59:59 PM)")
        case .usShort: return String(localized: "US Short (12/31/2024)")
        case .euLong: return String(localized: "EU Long (31/12/2024 23:59:59)")
        case .euShort: return String(localized: "EU Short (31/12/2024)")
        }
    }

    var formatString: String { rawValue }
}

/// Data grid settings
struct DataGridSettings: Codable, Equatable {
    var fontFamily: EditorFont
    var fontSize: Int
    var rowHeight: DataGridRowHeight
    var dateFormat: DateFormatOption
    var nullDisplay: String
    var defaultPageSize: Int
    var showAlternateRows: Bool
    var autoShowInspector: Bool

    static let `default` = DataGridSettings()

    init(
        fontFamily: EditorFont = .systemMono,
        fontSize: Int = 13,
        rowHeight: DataGridRowHeight = .normal,
        dateFormat: DateFormatOption = .iso8601,
        nullDisplay: String = "NULL",
        defaultPageSize: Int = 1_000,
        showAlternateRows: Bool = true,
        autoShowInspector: Bool = false
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.rowHeight = rowHeight
        self.dateFormat = dateFormat
        self.nullDisplay = nullDisplay
        self.defaultPageSize = defaultPageSize
        self.showAlternateRows = showAlternateRows
        self.autoShowInspector = autoShowInspector
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try container.decodeIfPresent(EditorFont.self, forKey: .fontFamily) ?? .systemMono
        fontSize = try container.decodeIfPresent(Int.self, forKey: .fontSize) ?? 13
        rowHeight = try container.decode(DataGridRowHeight.self, forKey: .rowHeight)
        dateFormat = try container.decode(DateFormatOption.self, forKey: .dateFormat)
        nullDisplay = try container.decode(String.self, forKey: .nullDisplay)
        defaultPageSize = try container.decode(Int.self, forKey: .defaultPageSize)
        showAlternateRows = try container.decode(Bool.self, forKey: .showAlternateRows)
        autoShowInspector = try container.decodeIfPresent(Bool.self, forKey: .autoShowInspector) ?? false
    }

    /// Clamped font size (10-18)
    var clampedFontSize: Int {
        min(max(fontSize, 10), 18)
    }

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
            return String(localized: "NULL display cannot be empty")
        } else if sanitized.count > maxLength {
            return String(localized: "NULL display must be \(maxLength) characters or less")
        } else if nullDisplay != sanitized {
            return String(localized: "NULL display contains invalid characters (newlines/tabs)")
        }
        return nil
    }

    /// Validation error for defaultPageSize (for UI feedback)
    var defaultPageSizeValidationError: String? {
        let range = SettingsValidationRules.defaultPageSizeRange
        if defaultPageSize < range.lowerBound || defaultPageSize > range.upperBound {
            return String(localized: "Page size must be between \(range.lowerBound.formatted()) and \(range.upperBound.formatted())")
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
            return String(localized: "Maximum entries cannot be negative")
        }
        return nil
    }

    /// Validation error for maxDays
    var maxDaysValidationError: String? {
        if maxDays < 0 {
            return String(localized: "Maximum days cannot be negative")
        }
        return nil
    }
}

// MARK: - Tab Settings

/// Tab behavior settings
struct TabSettings: Codable, Equatable {
    var enablePreviewTabs: Bool = true
    static let `default` = TabSettings()

    init(enablePreviewTabs: Bool = true) {
        self.enablePreviewTabs = enablePreviewTabs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enablePreviewTabs = try container.decodeIfPresent(Bool.self, forKey: .enablePreviewTabs) ?? true
    }
}
