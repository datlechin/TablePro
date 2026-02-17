//
//  SchemaStatementGenerator.swift
//  TablePro
//
//  Generates ALTER TABLE SQL statements from schema changes.
//  Supports MySQL, PostgreSQL, and SQLite with database-specific syntax.
//

import Foundation

/// A schema SQL statement with metadata
struct SchemaStatement {
    let sql: String
    let description: String
    let isDestructive: Bool
}

/// Generates SQL statements for schema modifications
struct SchemaStatementGenerator {
    private let databaseType: DatabaseType
    private let tableName: String

    /// Actual primary key constraint name (queried from database).
    /// Used by PostgreSQL which requires the constraint name for DROP CONSTRAINT.
    /// Falls back to `{table}_pkey` convention if nil.
    private let primaryKeyConstraintName: String?

    init(tableName: String, databaseType: DatabaseType, primaryKeyConstraintName: String? = nil) {
        self.tableName = tableName
        self.databaseType = databaseType
        self.primaryKeyConstraintName = primaryKeyConstraintName
    }

    /// Generate all SQL statements from schema changes
    func generate(changes: [SchemaChange]) throws -> [SchemaStatement] {
        var statements: [SchemaStatement] = []

        // Sort changes by dependency order
        let sortedChanges = sortByDependency(changes)

        for change in sortedChanges {
            let stmt = try generateStatement(for: change)
            // Ensure every statement ends with a semicolon
            let sql = stmt.sql.hasSuffix(";") ? stmt.sql : stmt.sql + ";"
            statements.append(SchemaStatement(sql: sql, description: stmt.description, isDestructive: stmt.isDestructive))
        }

        return statements
    }

    // MARK: - Dependency Ordering

    private func sortByDependency(_ changes: [SchemaChange]) -> [SchemaChange] {
        // Execution order for safety:
        // 1. Drop foreign keys first (includes modify FK, which requires drop+recreate)
        // 2. Drop indexes (includes modify index, which requires drop+recreate)
        // 3. Drop/modify columns
        // 4. Add columns
        // 5. Modify primary key
        // 6. Add indexes
        // 7. Add foreign keys

        var fkDeletes: [SchemaChange] = []  // Includes modifyForeignKey (drop+recreate)
        var indexDeletes: [SchemaChange] = []  // Includes modifyIndex (drop+recreate)
        var columnDeletes: [SchemaChange] = []
        var columnModifies: [SchemaChange] = []
        var columnAdds: [SchemaChange] = []
        var pkChanges: [SchemaChange] = []
        var indexAdds: [SchemaChange] = []
        var fkAdds: [SchemaChange] = []

        for change in changes {
            switch change {
            case .deleteForeignKey, .modifyForeignKey:
                // Modify FK is handled as drop+recreate, so group with deletes
                fkDeletes.append(change)
            case .deleteIndex, .modifyIndex:
                // Modify index is handled as drop+recreate, so group with deletes
                indexDeletes.append(change)
            case .deleteColumn:
                columnDeletes.append(change)
            case .modifyColumn:
                columnModifies.append(change)
            case .addColumn:
                columnAdds.append(change)
            case .modifyPrimaryKey:
                pkChanges.append(change)
            case .addIndex:
                indexAdds.append(change)
            case .addForeignKey:
                fkAdds.append(change)
            }
        }

        return fkDeletes + indexDeletes + columnDeletes + columnModifies + columnAdds + pkChanges + indexAdds + fkAdds
    }

    // MARK: - Statement Generation

    private func generateStatement(for change: SchemaChange) throws -> SchemaStatement {
        switch change {
        case .addColumn(let column):
            return try generateAddColumn(column)
        case .modifyColumn(let old, let new):
            return try generateModifyColumn(old: old, new: new)
        case .deleteColumn(let column):
            return generateDeleteColumn(column)
        case .addIndex(let index):
            return try generateAddIndex(index)
        case .modifyIndex(let old, let new):
            return try generateModifyIndex(old: old, new: new)
        case .deleteIndex(let index):
            return generateDeleteIndex(index)
        case .addForeignKey(let fk):
            return try generateAddForeignKey(fk)
        case .modifyForeignKey(let old, let new):
            return try generateModifyForeignKey(old: old, new: new)
        case .deleteForeignKey(let fk):
            return try generateDeleteForeignKey(fk)
        case .modifyPrimaryKey(let old, let new):
            return try generateModifyPrimaryKey(old: old, new: new)
        }
    }

    // MARK: - Column Operations

    private func generateAddColumn(_ column: EditableColumnDefinition) throws -> SchemaStatement {
        let tableQuoted = databaseType.quoteIdentifier(tableName)
        let columnDef = try buildEditableColumnDefinition(column)

        let sql = "ALTER TABLE \(tableQuoted) ADD COLUMN \(columnDef)"
        return SchemaStatement(
            sql: sql,
            description: "Add column '\(column.name)'",
            isDestructive: false
        )
    }

    private func generateModifyColumn(old: EditableColumnDefinition, new: EditableColumnDefinition) throws -> SchemaStatement {
        let tableQuoted = databaseType.quoteIdentifier(tableName)

        switch databaseType {
        case .mysql, .mariadb:
            let columnDef = try buildEditableColumnDefinition(new)
            let sql: String
            if old.name != new.name {
                // CHANGE COLUMN is required for renames: ALTER TABLE t CHANGE COLUMN old_name new_name definition
                let oldQuoted = databaseType.quoteIdentifier(old.name)
                sql = "ALTER TABLE \(tableQuoted) CHANGE COLUMN \(oldQuoted) \(columnDef)"
            } else {
                // MODIFY COLUMN when name is unchanged: ALTER TABLE t MODIFY COLUMN col definition
                sql = "ALTER TABLE \(tableQuoted) MODIFY COLUMN \(columnDef)"
            }
            return SchemaStatement(
                sql: sql,
                description: "Modify column '\(old.name)' to '\(new.name)'",
                isDestructive: old.dataType != new.dataType
            )

        case .postgresql:
            // PostgreSQL: Multiple ALTER COLUMN statements
            var statements: [String] = []
            let oldQuoted = databaseType.quoteIdentifier(old.name)
            let newQuoted = databaseType.quoteIdentifier(new.name)

            // Rename if needed
            if old.name != new.name {
                statements.append("ALTER TABLE \(tableQuoted) RENAME COLUMN \(oldQuoted) TO \(newQuoted)")
            }

            // Change type if needed
            if old.dataType != new.dataType {
                statements.append("ALTER TABLE \(tableQuoted) ALTER COLUMN \(newQuoted) TYPE \(new.dataType)")
            }

            // Change nullable if needed
            if old.isNullable != new.isNullable {
                let constraint = new.isNullable ? "DROP NOT NULL" : "SET NOT NULL"
                statements.append("ALTER TABLE \(tableQuoted) ALTER COLUMN \(newQuoted) \(constraint)")
            }

            // Change default if needed
            if old.defaultValue != new.defaultValue {
                if let defaultVal = new.defaultValue, !defaultVal.isEmpty {
                    statements.append("ALTER TABLE \(tableQuoted) ALTER COLUMN \(newQuoted) SET DEFAULT \(defaultVal)")
                } else {
                    statements.append("ALTER TABLE \(tableQuoted) ALTER COLUMN \(newQuoted) DROP DEFAULT")
                }
            }

            let sql = statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n")
            return SchemaStatement(
                sql: sql,
                description: "Modify column '\(old.name)' to '\(new.name)'",
                isDestructive: old.dataType != new.dataType
            )

        case .sqlite:
            // SQLite doesn't support ALTER COLUMN - requires table recreation
            // Throw error to prevent execution with incomplete implementation
            throw DatabaseError.unsupportedOperation
        }
    }

    private func generateDeleteColumn(_ column: EditableColumnDefinition) -> SchemaStatement {
        let tableQuoted = databaseType.quoteIdentifier(tableName)
        let columnQuoted = databaseType.quoteIdentifier(column.name)

        let sql = "ALTER TABLE \(tableQuoted) DROP COLUMN \(columnQuoted)"
        return SchemaStatement(
            sql: sql,
            description: "Drop column '\(column.name)'",
            isDestructive: true
        )
    }

    // MARK: - Column Definition Builder

    private func buildEditableColumnDefinition(_ column: EditableColumnDefinition) throws -> String {
        var parts: [String] = []

        parts.append(databaseType.quoteIdentifier(column.name))
        parts.append(column.dataType)

        // Unsigned (MySQL/MariaDB only)
        if (databaseType == .mysql || databaseType == .mariadb) && column.unsigned {
            parts.append("UNSIGNED")
        }

        // Nullable
        if !column.isNullable {
            parts.append("NOT NULL")
        }

        // Default value
        if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
            parts.append("DEFAULT \(defaultValue)")
        }

        // Auto increment
        if column.autoIncrement {
            switch databaseType {
            case .mysql, .mariadb:
                parts.append("AUTO_INCREMENT")
            case .postgresql:
                // PostgreSQL uses SERIAL or IDENTITY
                // For simplicity, we'll use SERIAL
                parts[1] = "SERIAL"
            case .sqlite:
                parts.append("AUTOINCREMENT")
            }
        }

        // On update (MySQL/MariaDB only for timestamp columns)
        if databaseType == .mysql || databaseType == .mariadb,
           let onUpdate = column.onUpdate, !onUpdate.isEmpty {
            parts.append("ON UPDATE \(onUpdate)")
        }

        // Comment
        if let comment = column.comment, !comment.isEmpty {
            switch databaseType {
            case .mysql, .mariadb:
                let escapedComment = comment.replacingOccurrences(of: "'", with: "''")
                parts.append("COMMENT '\(escapedComment)'")
            case .postgresql:
                // PostgreSQL comments are set via separate COMMENT statement
                break
            case .sqlite:
                // SQLite doesn't support column comments
                break
            }
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Index Operations

    private func generateAddIndex(_ index: EditableIndexDefinition) throws -> SchemaStatement {
        let tableQuoted = databaseType.quoteIdentifier(tableName)
        let indexQuoted = databaseType.quoteIdentifier(index.name)
        let columnsQuoted = index.columns.map { databaseType.quoteIdentifier($0) }.joined(separator: ", ")

        let uniqueKeyword = index.isUnique ? "UNIQUE " : ""

        let sql: String
        switch databaseType {
        case .mysql, .mariadb:
            let indexType = index.type.rawValue
            sql = "CREATE \(uniqueKeyword)INDEX \(indexQuoted) ON \(tableQuoted) (\(columnsQuoted)) USING \(indexType)"

        case .postgresql:
            let indexTypeClause = index.type == .btree ? "" : "USING \(index.type.rawValue)"
            sql = "CREATE \(uniqueKeyword)INDEX \(indexQuoted) ON \(tableQuoted) \(indexTypeClause) (\(columnsQuoted))"

        case .sqlite:
            sql = "CREATE \(uniqueKeyword)INDEX \(indexQuoted) ON \(tableQuoted) (\(columnsQuoted))"
        }

        return SchemaStatement(
            sql: sql,
            description: "Add index '\(index.name)'",
            isDestructive: false
        )
    }

    private func generateModifyIndex(old: EditableIndexDefinition, new: EditableIndexDefinition) throws -> SchemaStatement {
        // All databases require drop + recreate for index modification
        let dropStmt = generateDeleteIndex(old)
        let addStmt = try generateAddIndex(new)

        let sql = "\(dropStmt.sql);\n\(addStmt.sql);"
        return SchemaStatement(
            sql: sql,
            description: "Modify index '\(old.name)' to '\(new.name)'",
            isDestructive: false
        )
    }

    private func generateDeleteIndex(_ index: EditableIndexDefinition) -> SchemaStatement {
        let indexQuoted = databaseType.quoteIdentifier(index.name)

        let sql: String
        switch databaseType {
        case .mysql, .mariadb:
            let tableQuoted = databaseType.quoteIdentifier(tableName)
            sql = "DROP INDEX \(indexQuoted) ON \(tableQuoted)"

        case .postgresql, .sqlite:
            sql = "DROP INDEX \(indexQuoted)"
        }

        return SchemaStatement(
            sql: sql,
            description: "Drop index '\(index.name)'",
            isDestructive: false
        )
    }

    // MARK: - Foreign Key Operations

    private func generateAddForeignKey(_ fk: EditableForeignKeyDefinition) throws -> SchemaStatement {
        let tableQuoted = databaseType.quoteIdentifier(tableName)
        let fkQuoted = databaseType.quoteIdentifier(fk.name)
        let columnsQuoted = fk.columns.map { databaseType.quoteIdentifier($0) }.joined(separator: ", ")
        let refTableQuoted = databaseType.quoteIdentifier(fk.referencedTable)
        let refColumnsQuoted = fk.referencedColumns.map { databaseType.quoteIdentifier($0) }.joined(separator: ", ")

        let sql = """
        ALTER TABLE \(tableQuoted)
        ADD CONSTRAINT \(fkQuoted)
        FOREIGN KEY (\(columnsQuoted))
        REFERENCES \(refTableQuoted) (\(refColumnsQuoted))
        ON DELETE \(fk.onDelete.rawValue)
        ON UPDATE \(fk.onUpdate.rawValue)
        """

        return SchemaStatement(
            sql: sql,
            description: "Add foreign key '\(fk.name)'",
            isDestructive: false
        )
    }

    private func generateModifyForeignKey(old: EditableForeignKeyDefinition, new: EditableForeignKeyDefinition) throws -> SchemaStatement {
        // Modifying FK requires drop + recreate
        let dropStmt = try generateDeleteForeignKey(old)
        let addStmt = try generateAddForeignKey(new)

        let sql = "\(dropStmt.sql);\n\(addStmt.sql);"
        return SchemaStatement(
            sql: sql,
            description: "Modify foreign key '\(old.name)' to '\(new.name)'",
            isDestructive: false
        )
    }

    private func generateDeleteForeignKey(_ fk: EditableForeignKeyDefinition) throws -> SchemaStatement {
        let tableQuoted = databaseType.quoteIdentifier(tableName)
        let fkQuoted = databaseType.quoteIdentifier(fk.name)

        let sql: String
        switch databaseType {
        case .mysql, .mariadb:
            sql = "ALTER TABLE \(tableQuoted) DROP FOREIGN KEY \(fkQuoted)"

        case .postgresql:
            sql = "ALTER TABLE \(tableQuoted) DROP CONSTRAINT \(fkQuoted)"
        case .sqlite:
            throw DatabaseError.unsupportedOperation
        }
        return SchemaStatement(
            sql: sql,
            description: "Drop foreign key '\(fk.name)'",
            isDestructive: false
        )
    }

    // MARK: - Primary Key Operations

    private func generateModifyPrimaryKey(old: [String], new: [String]) throws -> SchemaStatement {
        let tableQuoted = databaseType.quoteIdentifier(tableName)
        let newColumnsQuoted = new.map { databaseType.quoteIdentifier($0) }.joined(separator: ", ")

        let sql: String
        switch databaseType {
        case .mysql, .mariadb:
            sql = """
            ALTER TABLE \(tableQuoted) DROP PRIMARY KEY;
            ALTER TABLE \(tableQuoted) ADD PRIMARY KEY (\(newColumnsQuoted));
            """

        case .postgresql:
            // Use actual constraint name if available, otherwise fall back to convention
            let pkName = primaryKeyConstraintName ?? "\(tableName)_pkey"
            sql = """
            ALTER TABLE \(tableQuoted) DROP CONSTRAINT \(databaseType.quoteIdentifier(pkName));
            ALTER TABLE \(tableQuoted) ADD PRIMARY KEY (\(newColumnsQuoted));
            """

        case .sqlite:
            // SQLite doesn't support modifying primary keys - requires table recreation
            // Throw error to prevent execution with incomplete implementation
            throw DatabaseError.unsupportedOperation
        }

        return SchemaStatement(
            sql: sql,
            description: "Modify primary key from [\(old.joined(separator: ", "))] to [\(new.joined(separator: ", "))]",
            isDestructive: true
        )
    }
}
