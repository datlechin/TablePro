//
//  SchemaStatementGeneratorPluginTests.swift
//  TableProTests
//
//  Tests for plugin-delegated DDL generation in SchemaStatementGenerator.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Mock plugin driver that returns custom DDL for specific operations.
/// Methods return nil by default (triggering fallback), unless overridden via closures.
private final class MockPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    var addColumnHandler: ((String, PluginColumnDefinition) -> String?)?
    var modifyColumnHandler: ((String, PluginColumnDefinition, PluginColumnDefinition) -> String?)?
    var dropColumnHandler: ((String, String) -> String?)?
    var addIndexHandler: ((String, PluginIndexDefinition) -> String?)?
    var dropIndexHandler: ((String, String) -> String?)?
    var addForeignKeyHandler: ((String, PluginForeignKeyDefinition) -> String?)?
    var dropForeignKeyHandler: ((String, String) -> String?)?
    var modifyPrimaryKeyHandler: ((String, [String], [String]) -> [String]?)?

    // MARK: - DDL Schema Generation

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        addColumnHandler?(table, column)
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        modifyColumnHandler?(table, oldColumn, newColumn)
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        dropColumnHandler?(table, columnName)
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        addIndexHandler?(table, index)
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        dropIndexHandler?(table, indexName)
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        addForeignKeyHandler?(table, fk)
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        dropForeignKeyHandler?(table, constraintName)
    }

    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String]) -> [String]? {
        modifyPrimaryKeyHandler?(table, oldColumns, newColumns)
    }

    // MARK: - Required Protocol Stubs

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchRowCount(query: String) async throws -> Int { 0 }
    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

@Suite("Schema Statement Generator - Plugin Delegation")
struct SchemaStatementGeneratorPluginTests {
    // MARK: - Helpers

    private func makeColumn(
        name: String = "email",
        dataType: String = "VARCHAR(255)",
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        defaultValue: String? = nil
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            defaultValue: defaultValue,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: isPrimaryKey
        )
    }

    private func makeIndex(
        name: String = "idx_email",
        columns: [String] = ["email"],
        isUnique: Bool = false
    ) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(),
            name: name,
            columns: columns,
            type: .btree,
            isUnique: isUnique,
            isPrimary: false,
            comment: nil
        )
    }

    private func makeForeignKey(
        name: String = "fk_user_role",
        columns: [String] = ["role_id"],
        refTable: String = "roles",
        refColumns: [String] = ["id"]
    ) -> EditableForeignKeyDefinition {
        EditableForeignKeyDefinition(
            id: UUID(),
            name: name,
            columns: columns,
            referencedTable: refTable,
            referencedColumns: refColumns,
            onDelete: .cascade,
            onUpdate: .noAction
        )
    }

    // MARK: - Fallback Tests (plugin returns nil)

    @Test("Add column falls back to default when plugin returns nil")
    func addColumnFallback() throws {
        let mock = MockPluginDriver()
        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .mysql, pluginDriver: mock
        )
        let column = makeColumn()
        let stmts = try generator.generate(changes: [.addColumn(column)])

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("ADD COLUMN"))
        #expect(stmts[0].sql.contains("`email`"))
    }

    @Test("Drop column falls back to default when plugin returns nil")
    func dropColumnFallback() throws {
        let mock = MockPluginDriver()
        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .mysql, pluginDriver: mock
        )
        let column = makeColumn()
        let stmts = try generator.generate(changes: [.deleteColumn(column)])

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("DROP COLUMN"))
    }

    @Test("No plugin driver uses default generation")
    func noPluginDriverDefault() throws {
        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .postgresql
        )
        let index = makeIndex()
        let stmts = try generator.generate(changes: [.addIndex(index)])

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("CREATE INDEX"))
    }

    // MARK: - Plugin Override Tests

    @Test("Add column uses plugin SQL when provided")
    func addColumnPluginOverride() throws {
        let mock = MockPluginDriver()
        mock.addColumnHandler = { table, col in
            "ALTER TABLE \(table) ADD \(col.name) \(col.dataType) CUSTOM_SYNTAX"
        }

        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .mysql, pluginDriver: mock
        )
        let column = makeColumn()
        let stmts = try generator.generate(changes: [.addColumn(column)])

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("CUSTOM_SYNTAX"))
        #expect(!stmts[0].sql.contains("ADD COLUMN"))
    }

    @Test("Modify column uses plugin SQL when provided")
    func modifyColumnPluginOverride() throws {
        let mock = MockPluginDriver()
        mock.modifyColumnHandler = { _, oldCol, newCol in
            "ALTER TABLE users CHANGE \(oldCol.name) TO \(newCol.name) PLUGIN_MODIFY"
        }

        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .mysql, pluginDriver: mock
        )
        let oldCol = makeColumn(name: "email")
        let newCol = makeColumn(name: "email_address")
        let stmts = try generator.generate(changes: [.modifyColumn(old: oldCol, new: newCol)])

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("PLUGIN_MODIFY"))
    }

    @Test("Drop column uses plugin SQL when provided")
    func dropColumnPluginOverride() throws {
        let mock = MockPluginDriver()
        mock.dropColumnHandler = { table, colName in
            "ALTER TABLE \(table) DROP \(colName) IF EXISTS"
        }

        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .mysql, pluginDriver: mock
        )
        let column = makeColumn()
        let stmts = try generator.generate(changes: [.deleteColumn(column)])

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("IF EXISTS"))
    }

    @Test("Add index uses plugin SQL when provided")
    func addIndexPluginOverride() throws {
        let mock = MockPluginDriver()
        mock.addIndexHandler = { table, idx in
            "CREATE INDEX \(idx.name) ON \(table) PLUGIN_INDEX"
        }

        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .mysql, pluginDriver: mock
        )
        let index = makeIndex()
        let stmts = try generator.generate(changes: [.addIndex(index)])

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("PLUGIN_INDEX"))
    }

    @Test("Drop index uses plugin SQL when provided")
    func dropIndexPluginOverride() throws {
        let mock = MockPluginDriver()
        mock.dropIndexHandler = { _, indexName in
            "DROP INDEX IF EXISTS \(indexName)"
        }

        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .mysql, pluginDriver: mock
        )
        let index = makeIndex()
        let stmts = try generator.generate(changes: [.deleteIndex(index)])

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("IF EXISTS"))
    }

    @Test("Add foreign key uses plugin SQL when provided")
    func addForeignKeyPluginOverride() throws {
        let mock = MockPluginDriver()
        mock.addForeignKeyHandler = { table, fk in
            "ALTER TABLE \(table) ADD FK \(fk.name) PLUGIN_FK"
        }

        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .mysql, pluginDriver: mock
        )
        let fk = makeForeignKey()
        let stmts = try generator.generate(changes: [.addForeignKey(fk)])

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("PLUGIN_FK"))
    }

    @Test("Drop foreign key uses plugin SQL when provided")
    func dropForeignKeyPluginOverride() throws {
        let mock = MockPluginDriver()
        mock.dropForeignKeyHandler = { _, constraintName in
            "ALTER TABLE users DROP CONSTRAINT \(constraintName) PLUGIN_DROP_FK"
        }

        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .mysql, pluginDriver: mock
        )
        let fk = makeForeignKey()
        let stmts = try generator.generate(changes: [.deleteForeignKey(fk)])

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("PLUGIN_DROP_FK"))
    }

    @Test("Modify primary key uses plugin SQL when provided")
    func modifyPrimaryKeyPluginOverride() throws {
        let mock = MockPluginDriver()
        mock.modifyPrimaryKeyHandler = { table, _, newCols in
            [
                "ALTER TABLE \(table) DROP PRIMARY KEY",
                "ALTER TABLE \(table) ADD PRIMARY KEY (\(newCols.joined(separator: ", "))) PLUGIN_PK"
            ]
        }

        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .mysql, pluginDriver: mock
        )
        let stmts = try generator.generate(changes: [.modifyPrimaryKey(old: ["id"], new: ["id", "tenant_id"])])

        #expect(stmts.count == 1)
        #expect(stmts[0].sql.contains("PLUGIN_PK"))
        #expect(stmts[0].isDestructive)
    }

    // MARK: - Mixed Override/Fallback

    @Test("Plugin overrides some operations while others fall back")
    func mixedPluginAndFallback() throws {
        let mock = MockPluginDriver()
        mock.addColumnHandler = { _, col in
            "PLUGIN_ADD_COL \(col.name)"
        }
        // dropColumnHandler is nil, so drop falls back to default

        let generator = SchemaStatementGenerator(
            tableName: "users", databaseType: .mysql, pluginDriver: mock
        )

        let addCol = makeColumn(name: "age", dataType: "INT")
        let dropCol = makeColumn(name: "old_field")

        let stmts = try generator.generate(changes: [
            .addColumn(addCol),
            .deleteColumn(dropCol)
        ])

        #expect(stmts.count == 2)

        // Drop comes first due to dependency ordering
        let dropStmt = stmts[0]
        #expect(dropStmt.sql.contains("DROP COLUMN"))
        #expect(!dropStmt.sql.contains("PLUGIN"))

        // Add uses plugin override
        let addStmt = stmts[1]
        #expect(addStmt.sql.contains("PLUGIN_ADD_COL"))
    }
}
