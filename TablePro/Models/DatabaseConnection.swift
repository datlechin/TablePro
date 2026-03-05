//
//  DatabaseConnection.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - SSH Configuration

/// SSH authentication method
enum SSHAuthMethod: String, CaseIterable, Identifiable, Codable {
    case password = "Password"
    case privateKey = "Private Key"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return String(localized: "Password")
        case .privateKey: return String(localized: "Private Key")
        }
    }

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

// MARK: - SSL Configuration

/// SSL/TLS connection mode
enum SSLMode: String, CaseIterable, Identifiable, Codable {
    case disabled = "Disabled"
    case preferred = "Preferred"
    case required = "Required"
    case verifyCa = "Verify CA"
    case verifyIdentity = "Verify Identity"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .disabled: return String(localized: "No SSL encryption")
        case .preferred: return String(localized: "Use SSL if available")
        case .required: return String(localized: "Require SSL, skip verification")
        case .verifyCa: return String(localized: "Verify server certificate")
        case .verifyIdentity: return String(localized: "Verify certificate and hostname")
        }
    }
}

/// SSL/TLS configuration for database connections
struct SSLConfiguration: Codable, Hashable {
    var mode: SSLMode = .disabled
    var caCertificatePath: String = ""
    var clientCertificatePath: String = ""
    var clientKeyPath: String = ""

    /// Whether SSL is effectively enabled
    var isEnabled: Bool { mode != .disabled }

    /// Whether certificate verification is enabled
    var verifiesCertificate: Bool { mode == .verifyCa || mode == .verifyIdentity }
}

// MARK: - Database Type

/// Represents the type of database
enum DatabaseType: String, CaseIterable, Identifiable, Codable {
    case mysql = "MySQL"
    case mariadb = "MariaDB"
    case postgresql = "PostgreSQL"
    case sqlite = "SQLite"
    case redshift = "Redshift"
    case mongodb = "MongoDB"
    case redis = "Redis"
    case mssql = "SQL Server"

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
        case .redshift:
            return "redshift-icon"
        case .mongodb:
            return "mongodb-icon"
        case .redis:
            return "redis-icon"
        case .mssql:
            return "mssql-icon"
        }
    }

    /// Default port for each database type
    var defaultPort: Int {
        switch self {
        case .mysql, .mariadb: return 3_306
        case .postgresql: return 5_432
        case .sqlite: return 0
        case .redshift: return 5_439
        case .mongodb: return 27_017
        case .redis: return 6_379
        case .mssql: return 1_433
        }
    }

    /// Whether this database type typically requires authentication credentials.
    /// MySQL, MariaDB, and PostgreSQL default to "root" when no username is provided;
    /// MongoDB and SQLite commonly run without authentication.
    var requiresAuthentication: Bool {
        switch self {
        case .mysql, .mariadb, .postgresql, .redshift, .mssql: return true
        case .sqlite, .mongodb, .redis: return false
        }
    }

    /// Whether this database type supports foreign key constraints
    var supportsForeignKeys: Bool {
        switch self {
        case .mysql, .mariadb, .postgresql, .sqlite, .redshift, .mssql:
            return true
        case .mongodb, .redis:
            return false
        }
    }

    /// Whether this database type supports SQL-based schema editing (ALTER TABLE etc.)
    var supportsSchemaEditing: Bool {
        switch self {
        case .mysql, .mariadb, .postgresql, .sqlite, .mssql:
            return true
        case .redshift, .mongodb, .redis:
            return false
        }
    }

    /// Quote character for identifiers (table/column names)
    /// MySQL/MariaDB/SQLite use backticks, PostgreSQL uses double quotes
    var identifierQuote: String {
        switch self {
        case .mysql, .mariadb, .sqlite:
            return "`"
        case .postgresql, .redshift, .mongodb, .redis:
            return "\""
        case .mssql:
            return "["
        }
    }

    /// Quote an identifier (table or column name) for this database type.
    /// Escapes embedded quote characters to prevent SQL injection.
    func quoteIdentifier(_ name: String) -> String {
        switch self {
        case .mongodb, .redis:
            return name
        case .mssql:
            return "[\(name.replacingOccurrences(of: "]", with: "]]"))]"
        default:
            let q = identifierQuote
            let escaped = name.replacingOccurrences(of: q, with: q + q)
            return "\(q)\(escaped)\(q)"
        }
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

    var displayName: String {
        switch self {
        case .none: return String(localized: "None")
        case .red: return String(localized: "Red")
        case .orange: return String(localized: "Orange")
        case .yellow: return String(localized: "Yellow")
        case .green: return String(localized: "Green")
        case .blue: return String(localized: "Blue")
        case .purple: return String(localized: "Purple")
        case .pink: return String(localized: "Pink")
        case .gray: return String(localized: "Gray")
        }
    }

    /// SwiftUI Color for display
    var color: Color {
        switch self {
        case .none: return .clear
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .blue: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .gray: return Color(nsColor: .systemGray)
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
    var sslConfig: SSLConfiguration
    var color: ConnectionColor
    var tagId: UUID?
    var groupId: UUID?
    var isReadOnly: Bool
    var aiPolicy: AIConnectionPolicy?
    var mongoReadPreference: String?
    var mongoWriteConcern: String?
    var redisDatabase: Int?
    var mssqlSchema: String?

    init(
        id: UUID = UUID(),
        name: String,
        host: String = "localhost",
        port: Int = 3_306,
        database: String = "",
        username: String = "root",
        type: DatabaseType = .mysql,
        sshConfig: SSHConfiguration = SSHConfiguration(),
        sslConfig: SSLConfiguration = SSLConfiguration(),
        color: ConnectionColor = .none,
        tagId: UUID? = nil,
        groupId: UUID? = nil,
        isReadOnly: Bool = false,
        aiPolicy: AIConnectionPolicy? = nil,
        mongoReadPreference: String? = nil,
        mongoWriteConcern: String? = nil,
        redisDatabase: Int? = nil,
        mssqlSchema: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.type = type
        self.sshConfig = sshConfig
        self.sslConfig = sslConfig
        self.color = color
        self.tagId = tagId
        self.groupId = groupId
        self.isReadOnly = isReadOnly
        self.aiPolicy = aiPolicy
        self.mongoReadPreference = mongoReadPreference
        self.mongoWriteConcern = mongoWriteConcern
        self.redisDatabase = redisDatabase
        self.mssqlSchema = mssqlSchema
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
