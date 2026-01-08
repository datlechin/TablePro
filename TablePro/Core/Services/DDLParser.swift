//
//  DDLParser.swift
//  TablePro
//
//  Simple DDL parser for importing CREATE TABLE statements
//

import Foundation

/// Parses CREATE TABLE DDL statements into TableCreationOptions
struct DDLParser {
    /// Parse a CREATE TABLE statement
    static func parse(_ ddl: String, databaseType: DatabaseType) throws -> TableCreationOptions {
        var options = TableCreationOptions()
        options.databaseName = "imported"

        // Extract table name
        if let tableName = extractTableName(from: ddl) {
            options.tableName = tableName
        } else {
            throw DDLParseError.invalidSyntax("Could not extract table name")
        }

        // Extract columns
        options.columns = try extractColumns(from: ddl, databaseType: databaseType)

        // Extract primary key
        options.primaryKeyColumns = extractPrimaryKey(from: ddl)

        // Extract engine (MySQL)
        if databaseType == .mysql || databaseType == .mariadb {
            options.engine = extractEngine(from: ddl)
            options.charset = extractCharset(from: ddl)
        }

        return options
    }

    // MARK: - Extraction Methods

    private static func extractTableName(from ddl: String) -> String? {
        // Pattern: CREATE TABLE `db`.`table` or CREATE TABLE table
        let patterns = [
            #"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[`\"]?(\w+)[`\"]?\.[`\"]?(\w+)[`\"]?"#,
            #"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[`\"]?(\w+)[`\"]?"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsString = ddl as NSString
                if let match = regex.firstMatch(in: ddl, range: NSRange(location: 0, length: nsString.length)) {
                    // If we have database.table pattern, use table name (second capture group)
                    if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                        return nsString.substring(with: match.range(at: 2))
                    }
                    // Otherwise use first capture group
                    if match.numberOfRanges > 1 {
                        return nsString.substring(with: match.range(at: 1))
                    }
                }
            }
        }

        return nil
    }

    private static func extractColumns(from ddl: String, databaseType: DatabaseType) throws -> [ColumnDefinition] {
        // Extract the content between parentheses
        guard let startIndex = ddl.firstIndex(of: "("),
              let endIndex = ddl.lastIndex(of: ")") else {
            throw DDLParseError.invalidSyntax("Missing parentheses")
        }

        let content = String(ddl[ddl.index(after: startIndex)..<endIndex])

        // Split by comma (but not within parentheses)
        let lines = splitByComma(content)

        var columns: [ColumnDefinition] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip constraints
            if trimmed.uppercased().hasPrefix("PRIMARY KEY") ||
                trimmed.uppercased().hasPrefix("FOREIGN KEY") ||
                trimmed.uppercased().hasPrefix("UNIQUE") ||
                trimmed.uppercased().hasPrefix("CONSTRAINT") ||
                trimmed.uppercased().hasPrefix("KEY") ||
                trimmed.uppercased().hasPrefix("INDEX") {
                continue
            }

            // Parse column definition
            if let column = parseColumnDefinition(trimmed, databaseType: databaseType) {
                columns.append(column)
            }
        }

        return columns
    }

    private static func parseColumnDefinition(_ line: String, databaseType: DatabaseType) -> ColumnDefinition? {
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }

        // Column name (remove quotes)
        var name = parts[0].replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\"", with: "")

        // Data type (may include length)
        var dataType = parts[1].uppercased()
        var length: Int?
        var precision: Int?

        // Extract length/precision from type (e.g., VARCHAR(255) or DECIMAL(10,2))
        if let openParen = dataType.firstIndex(of: "("),
           let closeParen = dataType.firstIndex(of: ")") {
            let typeBase = String(dataType[..<openParen])
            let lengthPart = String(dataType[dataType.index(after: openParen)..<closeParen])

            let lengthComponents = lengthPart.components(separatedBy: ",")
            if let first = lengthComponents.first, let len = Int(first.trimmingCharacters(in: .whitespaces)) {
                length = len
            }
            if lengthComponents.count > 1, let second = lengthComponents.last,
               let prec = Int(second.trimmingCharacters(in: .whitespaces)) {
                precision = prec
            }

            dataType = typeBase
        }

        // Parse attributes
        let upperLine = line.uppercased()
        let notNull = upperLine.contains("NOT NULL")
        let autoIncrement = upperLine.contains("AUTO_INCREMENT") ||
            upperLine.contains("AUTOINCREMENT") ||
            dataType.contains("SERIAL")

        // Extract default value
        var defaultValue: String?
        if let defaultMatch = try? NSRegularExpression(pattern: #"DEFAULT\s+([^,\s]+|'[^']*')"#, options: .caseInsensitive)
            .firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            let nsString = line as NSString
            defaultValue = nsString.substring(with: defaultMatch.range(at: 1))
                .trimmingCharacters(in: .init(charactersIn: "' "))
        }

        return ColumnDefinition(
            name: name,
            dataType: dataType,
            length: length,
            precision: precision,
            notNull: notNull,
            defaultValue: defaultValue,
            autoIncrement: autoIncrement
        )
    }

    private static func extractPrimaryKey(from ddl: String) -> [String] {
        // Pattern: PRIMARY KEY (`col1`, `col2`)
        let pattern = #"PRIMARY\s+KEY\s*\(([^)]+)\)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: ddl, range: NSRange(ddl.startIndex..., in: ddl)) else {
            return []
        }

        let nsString = ddl as NSString
        let columnsPart = nsString.substring(with: match.range(at: 1))

        return columnsPart.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "\"", with: "")
            }
            .filter { !$0.isEmpty }
    }

    private static func extractEngine(from ddl: String) -> String? {
        let pattern = #"ENGINE\s*=\s*(\w+)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: ddl, range: NSRange(ddl.startIndex..., in: ddl)) else {
            return nil
        }

        let nsString = ddl as NSString
        return nsString.substring(with: match.range(at: 1))
    }

    private static func extractCharset(from ddl: String) -> String? {
        let pattern = #"(?:DEFAULT\s+)?CHARSET\s*=\s*(\w+)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: ddl, range: NSRange(ddl.startIndex..., in: ddl)) else {
            return nil
        }

        let nsString = ddl as NSString
        return nsString.substring(with: match.range(at: 1))
    }

    // MARK: - Helper Methods

    private static func splitByComma(_ str: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0

        for char in str {
            if char == "(" {
                depth += 1
                current.append(char)
            } else if char == ")" {
                depth -= 1
                current.append(char)
            } else if char == "," && depth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }
}

// MARK: - Error

enum DDLParseError: LocalizedError {
    case invalidSyntax(String)

    var errorDescription: String? {
        switch self {
        case .invalidSyntax(let message):
            return "Invalid DDL syntax: \(message)"
        }
    }
}
