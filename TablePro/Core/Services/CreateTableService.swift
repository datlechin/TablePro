//
//  CreateTableService.swift
//  TablePro
//
//  Generates CREATE TABLE SQL statements from table creation options.
//  Supports MySQL/MariaDB, PostgreSQL, and SQLite with database-specific syntax.
//

import Foundation

/// Errors that can occur during table creation
enum CreateTableError: LocalizedError {
    case emptyTableName
    case emptyDatabaseName
    case noColumns
    case duplicateColumnName(String)
    case emptyColumnName(Int)
    case missingLength(columnName: String, dataType: String)
    case invalidLength(columnName: String, value: String)
    case multipleAutoIncrement
    case autoIncrementNotInteger(String)
    case invalidSQL(String)

    var errorDescription: String? {
        switch self {
        case .emptyTableName:
            return "Table name cannot be empty"
        case .emptyDatabaseName:
            return "Database name cannot be empty"
        case .noColumns:
            return "Table must have at least one column"
        case .duplicateColumnName(let name):
            return "Duplicate column name: '\(name)'"
        case .emptyColumnName(let index):
            return "Column #\(index + 1) has an empty name"
        case .missingLength(let columnName, let dataType):
            return "Column '\(columnName)' with type '\(dataType)' requires a length"
        case .invalidLength(let columnName, let value):
            return "Column '\(columnName)' has invalid length value: '\(value)'"
        case .multipleAutoIncrement:
            return "Only one column can have auto-increment enabled"
        case .autoIncrementNotInteger(let name):
            return "Auto-increment column '\(name)' must be an integer type"
        case .invalidSQL(let reason):
            return "Invalid SQL: \(reason)"
        }
    }
}

/// Service for generating CREATE TABLE SQL statements
struct CreateTableService {
    let databaseType: DatabaseType

    // MARK: - Public API

    /// Generate CREATE TABLE SQL from options
    /// - Parameter options: Table creation configuration
    /// - Returns: SQL CREATE TABLE statement
    /// - Throws: CreateTableError if validation fails
    func generateSQL(_ options: TableCreationOptions) throws -> String {
        // Validate options first
        try validate(options)

        // Generate database-specific SQL
        switch databaseType {
        case .mysql, .mariadb:
            return try generateMySQL(options)
        case .postgresql:
            return try generatePostgreSQL(options)
        case .sqlite:
            return try generateSQLite(options)
        }
    }

    /// Validate table creation options
    /// - Parameter options: Table creation configuration
    /// - Throws: CreateTableError if validation fails
    func validate(_ options: TableCreationOptions) throws {
        // Table name validation
        guard !options.tableName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CreateTableError.emptyTableName
        }

        // Database name validation (not required for SQLite)
        if databaseType != .sqlite {
            guard !options.databaseName.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CreateTableError.emptyDatabaseName
            }
        }

        // Must have at least one column
        guard !options.columns.isEmpty else {
            throw CreateTableError.noColumns
        }

        // Validate each column
        var columnNames = Set<String>()
        var autoIncrementCount = 0

        for (index, column) in options.columns.enumerated() {
            // Column name must not be empty
            let trimmedName = column.name.trimmingCharacters(in: .whitespaces)
            guard !trimmedName.isEmpty else {
                throw CreateTableError.emptyColumnName(index)
            }

            // Check for duplicate names (case-insensitive)
            let lowerName = trimmedName.lowercased()
            if columnNames.contains(lowerName) {
                throw CreateTableError.duplicateColumnName(trimmedName)
            }
            columnNames.insert(lowerName)

            // Validate length requirement for VARCHAR/CHAR types
            if requiresLength(dataType: column.dataType) && (column.length ?? 0) <= 0 {
                throw CreateTableError.missingLength(columnName: trimmedName, dataType: column.dataType)
            }

            // Validate length is a positive integer
            if let length = column.length, length <= 0 {
                throw CreateTableError.invalidLength(columnName: trimmedName, value: "\(length)")
            }

            // Count auto-increment columns
            if column.autoIncrement {
                autoIncrementCount += 1

                // Auto-increment must be on integer types
                if !isIntegerType(column.dataType) {
                    throw CreateTableError.autoIncrementNotInteger(trimmedName)
                }
            }
        }

        // Only one auto-increment column allowed (MySQL/SQLite limitation)
        if (databaseType == .mysql || databaseType == .mariadb || databaseType == .sqlite) && autoIncrementCount > 1 {
            throw CreateTableError.multipleAutoIncrement
        }
    }

    // MARK: - MySQL/MariaDB SQL Generation

    private func generateMySQL(_ options: TableCreationOptions) throws -> String {
        var sql = "CREATE TABLE "

        // Table name with database qualifier
        let quotedDatabase = databaseType.quoteIdentifier(options.databaseName)
        let quotedTable = databaseType.quoteIdentifier(options.tableName)
        sql += "\(quotedDatabase).\(quotedTable) (\n"

        // Column definitions
        let columnDefs = try options.columns.map { column -> String in
            let isPK = options.primaryKeyColumns.contains(column.name)
            return "  " + buildColumnDefinition(column, dbType: databaseType, isPK: isPK)
        }
        sql += columnDefs.joined(separator: ",\n")

        // Primary key constraint - only include columns that actually exist
        let existingColumnNames = Set(options.columns.map { $0.name })
        let validPKColumns = options.primaryKeyColumns.filter { existingColumnNames.contains($0) }
        if !validPKColumns.isEmpty {
            let pkColumns = validPKColumns.map { databaseType.quoteIdentifier($0) }
            sql += ",\n  PRIMARY KEY (\(pkColumns.joined(separator: ", ")))"
        }

        // Foreign key constraints
        for fk in options.foreignKeys where fk.isValid {
            sql += ",\n  " + buildForeignKeyConstraint(fk, dbType: databaseType)
        }

        // Unique constraints (from indexes marked as unique)
        for index in options.indexes where index.isUnique && index.isValid {
            let cols = index.columns.map { databaseType.quoteIdentifier($0) }
            let constraintName = index.name.isEmpty ? "" : "CONSTRAINT \(databaseType.quoteIdentifier(index.name)) "
            sql += ",\n  \(constraintName)UNIQUE (\(cols.joined(separator: ", ")))"
        }

        // Check constraints
        for check in options.checkConstraints where check.isValid {
            let constraintName = databaseType.quoteIdentifier(check.name)
            sql += ",\n  CONSTRAINT \(constraintName) CHECK (\(check.expression))"
        }

        sql += "\n)"

        // MySQL-specific options
        var tableOptions: [String] = []

        if let engine = options.engine, !engine.isEmpty {
            tableOptions.append("ENGINE=\(engine)")
        }

        if let charset = options.charset, !charset.isEmpty {
            tableOptions.append("DEFAULT CHARSET=\(charset)")
        }

        if let collation = options.collation, !collation.isEmpty {
            tableOptions.append("COLLATE=\(collation)")
        }

        if !tableOptions.isEmpty {
            sql += " " + tableOptions.joined(separator: " ")
        }

        sql += ";"

        // Add comment as separate statement if provided
        if let comment = options.comment, !comment.trimmingCharacters(in: .whitespaces).isEmpty {
            sql += "\nALTER TABLE \(quotedDatabase).\(quotedTable) COMMENT '\(escapeSQLString(comment))';"
        }

        // Add indexes as separate statements (non-unique indexes)
        for index in options.indexes where !index.isUnique && index.isValid {
            let indexName = databaseType.quoteIdentifier(index.name)
            let cols = index.columns.map { databaseType.quoteIdentifier($0) }.joined(separator: ", ")
            let indexType = index.type == .btree ? "" : " USING \(index.type.rawValue)"
            sql += "\nCREATE INDEX \(indexName) ON \(quotedDatabase).\(quotedTable) (\(cols))\(indexType);"
        }

        return sql
    }

    // MARK: - PostgreSQL SQL Generation

    private func generatePostgreSQL(_ options: TableCreationOptions) throws -> String {
        var sql = "CREATE TABLE "

        // Table name with schema qualifier
        let quotedSchema = databaseType.quoteIdentifier(options.databaseName)
        let quotedTable = databaseType.quoteIdentifier(options.tableName)
        sql += "\(quotedSchema).\(quotedTable) (\n"

        // Column definitions
        let columnDefs = try options.columns.map { column -> String in
            let isPK = options.primaryKeyColumns.contains(column.name)
            return "  " + buildColumnDefinition(column, dbType: databaseType, isPK: isPK)
        }
        sql += columnDefs.joined(separator: ",\n")

        // Primary key constraint - only include columns that actually exist
        let existingColumnNames = Set(options.columns.map { $0.name })
        let validPKColumns = options.primaryKeyColumns.filter { existingColumnNames.contains($0) }
        if !validPKColumns.isEmpty {
            let pkColumns = validPKColumns.map { databaseType.quoteIdentifier($0) }
            sql += ",\n  PRIMARY KEY (\(pkColumns.joined(separator: ", ")))"
        }

        // Foreign key constraints
        for fk in options.foreignKeys where fk.isValid {
            sql += ",\n  " + buildForeignKeyConstraint(fk, dbType: databaseType)
        }

        // Unique constraints (from indexes marked as unique)
        for index in options.indexes where index.isUnique && index.isValid {
            let cols = index.columns.map { databaseType.quoteIdentifier($0) }
            let constraintName = index.name.isEmpty ? "" : "CONSTRAINT \(databaseType.quoteIdentifier(index.name)) "
            sql += ",\n  \(constraintName)UNIQUE (\(cols.joined(separator: ", ")))"
        }

        // Check constraints
        for check in options.checkConstraints where check.isValid {
            let constraintName = databaseType.quoteIdentifier(check.name)
            sql += ",\n  CONSTRAINT \(constraintName) CHECK (\(check.expression))"
        }

        sql += "\n);"

        // Add tablespace if provided
        if let tablespace = options.tablespace, !tablespace.trimmingCharacters(in: .whitespaces).isEmpty {
            sql = sql.dropLast() + " TABLESPACE \(databaseType.quoteIdentifier(tablespace));"
        }

        // Add comment as separate statement if provided
        if let comment = options.comment, !comment.trimmingCharacters(in: .whitespaces).isEmpty {
            sql += "\nCOMMENT ON TABLE \(quotedSchema).\(quotedTable) IS '\(escapeSQLString(comment))';"
        }

        // Add column comments
        for column in options.columns {
            if let comment = column.comment, !comment.trimmingCharacters(in: .whitespaces).isEmpty {
                let quotedColumn = databaseType.quoteIdentifier(column.name)
                sql += "\nCOMMENT ON COLUMN \(quotedSchema).\(quotedTable).\(quotedColumn) IS '\(escapeSQLString(comment))';"
            }
        }

        // Add indexes as separate statements (non-unique indexes)
        for index in options.indexes where !index.isUnique && index.isValid {
            let indexName = databaseType.quoteIdentifier(index.name)
            let cols = index.columns.map { databaseType.quoteIdentifier($0) }.joined(separator: ", ")
            let indexType = index.type == .btree ? "" : " USING \(index.type.rawValue)"
            sql += "\nCREATE INDEX \(indexName) ON \(quotedSchema).\(quotedTable)\(indexType) (\(cols));"
        }

        return sql
    }

    // MARK: - SQLite SQL Generation

    private func generateSQLite(_ options: TableCreationOptions) throws -> String {
        var sql = "CREATE TABLE "

        // Table name (no database qualifier in SQLite)
        let quotedTable = databaseType.quoteIdentifier(options.tableName)
        sql += "\(quotedTable) (\n"

        // Column definitions
        // SQLite handles PRIMARY KEY differently for single vs composite keys
        // First, filter to only valid columns that exist
        let existingColumnNames = Set(options.columns.map { $0.name })
        let validPKColumns = options.primaryKeyColumns.filter { existingColumnNames.contains($0) }

        let hasSinglePK = validPKColumns.count == 1
        let singlePKColumn = hasSinglePK ? validPKColumns.first : nil

        let columnDefs = try options.columns.map { column -> String in
            // For single PK, add PRIMARY KEY inline
            let isPKInline = singlePKColumn == column.name
            return "  " + buildColumnDefinition(column, dbType: databaseType, isPK: isPKInline)
        }
        sql += columnDefs.joined(separator: ",\n")

        // For composite keys (multiple columns), add PRIMARY KEY constraint
        if validPKColumns.count > 1 {
            let pkColumns = validPKColumns.map { databaseType.quoteIdentifier($0) }
            sql += ",\n  PRIMARY KEY (\(pkColumns.joined(separator: ", ")))"
        }

        sql += "\n);"

        return sql
    }

    // MARK: - Column Definition Builder

    /// Build a complete column definition string
    /// - Parameters:
    ///   - column: Column configuration
    ///   - dbType: Database type for syntax differences
    ///   - isPK: Whether this column is (part of) the primary key
    /// - Returns: Column definition SQL fragment
    private func buildColumnDefinition(_ column: ColumnDefinition, dbType: DatabaseType, isPK: Bool) -> String {
        var parts: [String] = []

        // Column name
        parts.append(dbType.quoteIdentifier(column.name))

        // Data type with length/precision
        var dataType = column.dataType.uppercased()

        // Handle SERIAL type for PostgreSQL (replaces INT + AUTO_INCREMENT)
        if dbType == .postgresql && column.autoIncrement && isIntegerType(column.dataType) {
            switch column.dataType.uppercased() {
            case "SMALLINT":
                dataType = "SMALLSERIAL"
            case "INT", "INTEGER":
                dataType = "SERIAL"
            case "BIGINT":
                dataType = "BIGSERIAL"
            default:
                dataType = "SERIAL"
            }
        }
        // Add length/precision if applicable
        else if let length = column.length, length > 0 {
            if let precision = column.precision, precision > 0 {
                dataType += "(\(length), \(precision))"
            } else {
                dataType += "(\(length))"
            }
        }

        parts.append(dataType)

        // Unsigned (MySQL only)
        if (dbType == .mysql || dbType == .mariadb) && column.unsigned {
            parts.append("UNSIGNED")
        }

        // Zerofill (MySQL only)
        if (dbType == .mysql || dbType == .mariadb) && column.zerofill {
            parts.append("ZEROFILL")
        }

        // NOT NULL / NULL
        if column.notNull {
            parts.append("NOT NULL")
        } else if dbType == .postgresql {
            // PostgreSQL: explicitly add NULL for clarity (optional but good practice)
            parts.append("NULL")
        }

        // Default value
        if let defaultValue = column.defaultValue, !defaultValue.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = defaultValue.trimmingCharacters(in: .whitespaces)
            if isSQLFunction(trimmed) {
                parts.append("DEFAULT \(trimmed.uppercased())")
            } else if trimmed.uppercased() == "NULL" {
                parts.append("DEFAULT NULL")
            } else if isBooleanLiteral(trimmed) {
                parts.append("DEFAULT \(trimmed.uppercased())")
            } else if isNumericLiteral(trimmed) {
                parts.append("DEFAULT \(trimmed)")
            } else {
                // Check if the value is already a quoted string
                if (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) ||
                    (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) {
                    // Already quoted, use as-is
                    parts.append("DEFAULT \(trimmed)")
                } else {
                    // Not quoted, escape and quote it
                    parts.append("DEFAULT '\(escapeSQLString(trimmed))'")
                }
            }
        }

        // Auto-increment
        // PostgreSQL: handled by SERIAL type above
        // MySQL/MariaDB: AUTO_INCREMENT keyword
        // SQLite: AUTOINCREMENT keyword (only for INTEGER PRIMARY KEY)
        if column.autoIncrement && dbType != .postgresql {
            if dbType == .sqlite {
                // SQLite: AUTOINCREMENT only valid with INTEGER PRIMARY KEY
                if isPK && column.dataType.uppercased().contains("INT") {
                    parts.append("AUTOINCREMENT")
                }
            } else {
                // MySQL/MariaDB
                parts.append("AUTO_INCREMENT")
            }
        }

        // Primary key inline (SQLite single-column PK only)
        if isPK && dbType == .sqlite && column.autoIncrement {
            // For SQLite with autoincrement, PRIMARY KEY goes before AUTOINCREMENT
            let pkIndex = parts.firstIndex(of: "AUTOINCREMENT") ?? parts.count
            parts.insert("PRIMARY KEY", at: pkIndex)
        } else if isPK && dbType == .sqlite {
            parts.append("PRIMARY KEY")
        }

        // Comment (MySQL inline)
        if dbType == .mysql || dbType == .mariadb {
            if let comment = column.comment, !comment.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("COMMENT '\(escapeSQLString(comment))'")
            }
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Constraint Builders

    /// Build a foreign key constraint definition
    /// - Parameters:
    ///   - fk: Foreign key constraint
    ///   - dbType: Database type for syntax differences
    /// - Returns: Foreign key constraint SQL fragment
    private func buildForeignKeyConstraint(_ fk: ForeignKeyConstraint, dbType: DatabaseType) -> String {
        var parts: [String] = []

        // Constraint name (optional)
        if !fk.name.isEmpty {
            parts.append("CONSTRAINT \(dbType.quoteIdentifier(fk.name))")
        }

        // FOREIGN KEY (columns)
        let localCols = fk.columns.map { dbType.quoteIdentifier($0) }.joined(separator: ", ")
        parts.append("FOREIGN KEY (\(localCols))")

        // REFERENCES table(columns)
        let refTable = dbType.quoteIdentifier(fk.referencedTable)
        let refCols = fk.referencedColumns.map { dbType.quoteIdentifier($0) }.joined(separator: ", ")
        parts.append("REFERENCES \(refTable)(\(refCols))")

        // ON DELETE action
        if fk.onDelete != .noAction {
            parts.append("ON DELETE \(fk.onDelete.rawValue)")
        }

        // ON UPDATE action
        if fk.onUpdate != .noAction {
            parts.append("ON UPDATE \(fk.onUpdate.rawValue)")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Helper Functions

    /// Check if a data type requires a length specification
    private func requiresLength(dataType: String) -> Bool {
        let type = dataType.uppercased()
        return type == "VARCHAR" || type == "CHAR" || type == "VARBINARY" || type == "BINARY"
    }

    /// Check if a data type is an integer type (for auto-increment validation)
    private func isIntegerType(_ dataType: String) -> Bool {
        let type = dataType.uppercased()
        let integerTypes = ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT", "SERIAL", "SMALLSERIAL", "BIGSERIAL"]
        return integerTypes.contains(type)
    }

    /// Check if a string is a SQL function that should not be quoted
    private func isSQLFunction(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces).uppercased()

        let sqlFunctions = [
            "NOW()",
            "CURRENT_TIMESTAMP()",
            "CURRENT_TIMESTAMP",
            "CURDATE()",
            "CURTIME()",
            "UTC_TIMESTAMP()",
            "UTC_DATE()",
            "UTC_TIME()",
            "LOCALTIME()",
            "LOCALTIME",
            "LOCALTIMESTAMP()",
            "LOCALTIMESTAMP",
            "SYSDATE()",
            "UNIX_TIMESTAMP()",
            "CURRENT_DATE()",
            "CURRENT_DATE",
            "CURRENT_TIME()",
            "CURRENT_TIME",
            "CURRENT_USER",
            "CURRENT_USER()",
            "UUID()",
            "GEN_RANDOM_UUID()",
        ]

        return sqlFunctions.contains(trimmed)
    }

    /// Check if a value is a boolean literal
    private func isBooleanLiteral(_ value: String) -> Bool {
        let upper = value.uppercased()
        return upper == "TRUE" || upper == "FALSE"
    }

    /// Check if a value is a numeric literal
    private func isNumericLiteral(_ value: String) -> Bool {
        // Simple check: can be parsed as Int or Double
        Int(value) != nil || Double(value) != nil
    }

    /// Escape characters that can break SQL strings
    /// Delegates to shared SQLEscaping utility for consistent escaping across the codebase
    private func escapeSQLString(_ str: String) -> String {
        SQLEscaping.escapeStringLiteral(str)
    }
}

// MARK: - Preview Helpers

extension CreateTableService {
    /// Generate a formatted preview SQL for display (with prettier formatting)
    func generatePreviewSQL(_ options: TableCreationOptions) -> String {
        do {
            return try generateSQL(options)
        } catch {
            return "-- Error: \(error.localizedDescription)"
        }
    }
}
