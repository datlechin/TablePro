//
//  Theme.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import AppKit
import SwiftUI

/// App-wide theme colors and styles
enum Theme {
    // MARK: - Brand Colors

    static let primaryColor = Color("AccentColor")

    static let mysqlColor = Color(nsColor: .systemOrange)
    static let postgresqlColor = Color(nsColor: .systemBlue)
    static let sqliteColor = Color(nsColor: .systemGreen)
    static let mariadbColor = Color(nsColor: .systemCyan)
    static let mongodbColor = Color(red: 0.0, green: 0.93, blue: 0.39)
    static let redshiftColor = Color(red: 0.13, green: 0.36, blue: 0.59)
    static let redisColor = Color(red: 0.86, green: 0.22, blue: 0.18) // #DC382D
    static let mssqlColor = Color(red: 0.89, green: 0.27, blue: 0.09)
    static let oracleColor = Color(red: 0.76, green: 0.09, blue: 0.07) // #C3160B Oracle red
    static let clickhouseColor = Color(red: 1.0, green: 0.82, blue: 0.0)
    static let duckdbColor = Color(red: 1.0, green: 0.85, blue: 0.0)
    static let defaultDatabaseColor = Color.gray

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

    static let nullValue = Color(nsColor: .tertiaryLabelColor)
    static let boolTrue = Color(nsColor: .systemGreen)
    static let boolFalse = Color(nsColor: .systemRed)

    // MARK: - Status Colors

    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let error = Color(nsColor: .systemRed)
    static let info = Color(nsColor: .systemBlue)

    // MARK: - Connection Status

    static let connected = Color(nsColor: .systemGreen)
    static let disconnected = Color(nsColor: .systemGray)
    static let connecting = Color(nsColor: .systemOrange)
}

// MARK: - View Extensions

extension View {
    /// Apply card-like styling
    func cardStyle() -> some View {
        self
            .background(Theme.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
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
        Self.themeColorMap[self] ?? Theme.defaultDatabaseColor
    }

    private static let themeColorMap: [DatabaseType: Color] = [
        .mysql: Theme.mysqlColor,
        .mariadb: Theme.mariadbColor,
        .postgresql: Theme.postgresqlColor,
        .sqlite: Theme.sqliteColor,
        .redshift: Theme.redshiftColor,
        .mongodb: Theme.mongodbColor,
        .redis: Theme.redisColor,
        .mssql: Theme.mssqlColor,
        .oracle: Theme.oracleColor,
        .clickhouse: Theme.clickhouseColor,
        .duckdb: Theme.duckdbColor,
    ]
}
