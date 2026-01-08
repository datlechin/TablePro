//
//  DatabaseConnection.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import SwiftUI

// MARK: - SSH Configuration

/// SSH authentication method
enum SSHAuthMethod: String, CaseIterable, Identifiable, Codable {
    case password = "Password"
    case privateKey = "Private Key"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .password: return "key.fill"
        case .privateKey: return "doc.text.fill"
        }
    }
}

/// SSH tunnel configuration for database connections
struct SSHConfiguration: Codable, Hashable {
    var enabled: Bool = false
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authMethod: SSHAuthMethod = .password
    var privateKeyPath: String = ""  // Path to identity file (e.g., ~/.ssh/id_rsa)
    var useSSHConfig: Bool = true  // Auto-fill from ~/.ssh/config when selecting host

    /// Check if SSH configuration is complete enough for connection
    var isValid: Bool {
        guard enabled else { return true }  // Not enabled = valid (skip SSH)
        guard !host.isEmpty, !username.isEmpty else { return false }

        switch authMethod {
        case .password:
            return true  // Password will be provided separately
        case .privateKey:
            return !privateKeyPath.isEmpty
        }
    }
}

// MARK: - Database Type

/// Represents the type of database
enum DatabaseType: String, CaseIterable, Identifiable, Codable {
    case mysql = "MySQL"
    case mariadb = "MariaDB"
    case postgresql = "PostgreSQL"
    case sqlite = "SQLite"

    var id: String { rawValue }

    /// Asset name for each database type icon
    var iconName: String {
        switch self {
        case .mysql:
            return "mysql-icon"
        case .mariadb:
            return "mariadb-icon"
        case .postgresql:
            return "postgresql-icon"
        case .sqlite:
            return "sqlite-icon"
        }
    }

    /// Default port for each database type
    var defaultPort: Int {
        switch self {
        case .mysql, .mariadb: return 3_306
        case .postgresql: return 5_432
        case .sqlite: return 0
        }
    }

    /// Quote character for identifiers (table/column names)
    /// MySQL/MariaDB/SQLite use backticks, PostgreSQL uses double quotes
    var identifierQuote: String {
        switch self {
        case .mysql, .mariadb, .sqlite:
            return "`"
        case .postgresql:
            return "\""
        }
    }

    /// Quote an identifier (table or column name) for this database type.
    /// Escapes embedded quote characters to prevent SQL injection.
    func quoteIdentifier(_ name: String) -> String {
        let q = identifierQuote
        // Escape embedded quotes by doubling them (SQL standard)
        let escaped = name.replacingOccurrences(of: q, with: q + q)
        return "\(q)\(escaped)\(q)"
    }
}

// MARK: - Connection Color

/// Preset colors for connection status indicators
enum ConnectionColor: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case gray = "Gray"

    var id: String { rawValue }

    /// SwiftUI Color for display
    var color: Color {
        switch self {
        case .none: return .clear
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }

    /// Whether this represents "no custom color"
    var isDefault: Bool { self == .none }
}

// MARK: - Database Connection

/// Model representing a database connection
struct DatabaseConnection: Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var database: String
    var username: String
    var type: DatabaseType
    var sshConfig: SSHConfiguration
    var color: ConnectionColor
    var tagId: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        host: String = "localhost",
        port: Int = 3_306,
        database: String = "",
        username: String = "root",
        type: DatabaseType = .mysql,
        sshConfig: SSHConfiguration = SSHConfiguration(),
        color: ConnectionColor = .none,
        tagId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.type = type
        self.sshConfig = sshConfig
        self.color = color
        self.tagId = tagId
    }

    /// Returns the display color (custom color or database type color)
    var displayColor: Color {
        color.isDefault ? type.themeColor : color.color
    }
}

// MARK: - Sample Data for Development

extension DatabaseConnection {
    static let sampleConnections: [DatabaseConnection] = []
}

// MARK: - Codable Conformance

extension DatabaseConnection: Codable {}
