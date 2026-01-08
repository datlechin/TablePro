//
//  Theme.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import SwiftUI

/// App-wide theme colors and styles
enum Theme {
    // MARK: - Brand Colors

    static let primaryColor = Color("AccentColor")

    static let mysqlColor = Color.orange
    static let postgresqlColor = Color.blue
    static let sqliteColor = Color.green
    static let mariadbColor = Color.cyan

    // MARK: - Semantic Colors

    static var background: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var secondaryBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var textBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    static var separator: Color {
        Color(nsColor: .separatorColor)
    }

    // MARK: - Editor Colors

    static let editorBackground = Color(nsColor: .textBackgroundColor)
    static let editorFont = Font.system(.body, design: .monospaced)

    static let syntaxKeyword = Color.pink
    static let syntaxString = Color.green
    static let syntaxNumber = Color.blue
    static let syntaxComment = Color.gray

    // MARK: - Results Table Colors

    static var tableAlternateRow: Color {
        Color(nsColor: .alternatingContentBackgroundColors[1])
    }

    static let nullValue = Color.secondary.opacity(0.5)
    static let boolTrue = Color.green
    static let boolFalse = Color.red

    // MARK: - Status Colors

    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let info = Color.blue

    // MARK: - Connection Status

    static let connected = Color.green
    static let disconnected = Color.gray
    static let connecting = Color.orange
}

// MARK: - View Extensions

extension View {
    /// Apply card-like styling
    func cardStyle() -> some View {
        self
            .background(Theme.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Apply toolbar button styling
    func toolbarButtonStyle() -> some View {
        self
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Database Type Colors

extension DatabaseType {
    var themeColor: Color {
        switch self {
        case .mysql:
            return Theme.mysqlColor
        case .mariadb:
            return Theme.mariadbColor
        case .postgresql:
            return Theme.postgresqlColor
        case .sqlite:
            return Theme.sqliteColor
        }
    }
}
