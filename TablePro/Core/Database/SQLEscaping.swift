//
//  SQLEscaping.swift
//  TablePro
//
//  Shared utilities for SQL string escaping to prevent SQL injection.
//  Used across ExportService, SQLStatementGenerator, and other SQL-generating code.
//

import Foundation

/// Centralized SQL escaping utilities to prevent SQL injection vulnerabilities
enum SQLEscaping {
    /// Escape a string value for use in SQL string literals (VALUES, WHERE clauses, etc.)
    ///
    /// MySQL/MariaDB: Uses backslash escape sequences for control characters (`\n`, `\t`, etc.)
    /// PostgreSQL/SQLite: Uses standard SQL escaping (only single quotes doubled).
    /// Newlines, tabs, and backslashes are valid as-is in standard SQL string literals.
    ///
    /// Example:
    /// ```swift
    /// let safe = SQLEscaping.escapeStringLiteral("O'Brien\\test", databaseType: .mysql)
    /// // Result: "O''Brien\\\\test"
    /// let safe2 = SQLEscaping.escapeStringLiteral("O'Brien\\test", databaseType: .postgresql)
    /// // Result: "O''Brien\\test"
    /// ```
    ///
    /// - Parameters:
    ///   - str: The raw string to escape
    ///   - databaseType: The target database type (defaults to `.mysql` for backward compatibility)
    /// - Returns: The escaped string safe for use in SQL string literals
    static func escapeStringLiteral(_ str: String, databaseType: DatabaseType = .mysql) -> String {
        switch databaseType {
        case .mysql, .mariadb:
            // MySQL/MariaDB: backslash escaping is active by default
            var result = str
            // IMPORTANT: Escape backslashes FIRST to avoid double-escaping
            result = result.replacingOccurrences(of: "\\", with: "\\\\")
            // Single quote: SQL standard escaping (double the quote)
            result = result.replacingOccurrences(of: "'", with: "''")
            // Common control characters
            result = result.replacingOccurrences(of: "\n", with: "\\n")
            result = result.replacingOccurrences(of: "\r", with: "\\r")
            result = result.replacingOccurrences(of: "\t", with: "\\t")
            result = result.replacingOccurrences(of: "\0", with: "\\0")
            // Additional control characters that can cause issues
            result = result.replacingOccurrences(of: "\u{08}", with: "\\b")  // Backspace
            result = result.replacingOccurrences(of: "\u{0C}", with: "\\f")  // Form feed
            result = result.replacingOccurrences(of: "\u{1A}", with: "\\Z")  // MySQL EOF marker (Ctrl+Z)
            return result

        case .postgresql, .redshift, .sqlite, .mongodb, .redis, .mssql:
            // Standard SQL: only single quotes need doubling
            // Newlines, tabs, backslashes are valid as-is in string literals
            var result = str
            result = result.replacingOccurrences(of: "'", with: "''")
            // Strip null bytes (PostgreSQL rejects them in text)
            result = result.replacingOccurrences(of: "\0", with: "")
            return result
        }
    }

    /// Escape wildcards in LIKE patterns while preserving intentional wildcards
    ///
    /// This is useful when building LIKE clauses where the search term should be treated literally.
    ///
    /// - Parameter value: The value to escape
    /// - Returns: The escaped value with %, _, and \ escaped
    static func escapeLikeWildcards(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "%", with: "\\%")
        result = result.replacingOccurrences(of: "_", with: "\\_")
        return result
    }
}
