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
    /// Handles the following special characters:
    /// - Backslashes (must be escaped first to avoid double-escaping)
    /// - Single quotes (SQL standard: doubled)
    /// - Control characters: null, backspace, tab, newline, form feed, carriage return
    /// - MySQL EOF marker (\x1A) which can cause parsing issues
    ///
    /// Example:
    /// ```swift
    /// let safe = SQLEscaping.escapeStringLiteral("O'Brien\\test")
    /// // Result: "O''Brien\\\\test"
    /// let sql = "INSERT INTO users (name) VALUES ('\(safe)')"
    /// ```
    ///
    /// - Parameter str: The raw string to escape
    /// - Returns: The escaped string safe for use in SQL string literals
    static func escapeStringLiteral(_ str: String) -> String {
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
