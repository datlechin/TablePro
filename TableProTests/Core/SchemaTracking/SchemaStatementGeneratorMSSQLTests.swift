//
//  SchemaStatementGeneratorMSSQLTests.swift
//  TableProTests
//
//  Tests for SchemaStatementGenerator with databaseType: .mssql
//

import Foundation
@testable import TablePro
import Testing

@Suite("Schema Statement Generator MSSQL")
struct SchemaStatementGeneratorMSSQLTests {
    // MARK: - Helpers

    private func makeGenerator(
        table: String = "users",
        pkConstraint: String? = nil
    ) -> SchemaStatementGenerator {
        SchemaStatementGenerator(
            tableName: table,
            databaseType: .mssql,
            primaryKeyConstraintName: pkConstraint
        )
    }

    private func makeColumn(
        name: String = "email",
        dataType: String = "NVARCHAR(255)",
        isNullable: Bool = false
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false
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

    private func makeFK(
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

    // MARK: - Column Tests

    @Test("Add column uses ADD (not ADD COLUMN) for MSSQL")
    func addColumnUsesAddKeyword() throws {
        let generator = makeGenerator()
        let column = makeColumn(name: "email", dataType: "NVARCHAR(255)", isNullable: false)
        let statements = try generator.generate(changes: [.addColumn(column)])

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("ALTER TABLE [users] ADD"))
        #expect(!sql.contains("ADD COLUMN"))
        #expect(sql.contains("[email]"))
        #expect(sql.contains("NVARCHAR(255)"))
        #expect(sql.contains("NOT NULL"))
    }

    @Test("Rename column uses EXEC sp_rename syntax")
    func renameColumnUsesSPRename() throws {
        let generator = makeGenerator()
        let old = makeColumn(name: "old_name", dataType: "NVARCHAR(100)")
        let new = makeColumn(name: "new_name", dataType: "NVARCHAR(100)")
        let statements = try generator.generate(changes: [.modifyColumn(old: old, new: new)])

        let allSQL = statements.map { $0.sql }.joined(separator: "\n")
        #expect(allSQL.contains("sp_rename"))
        #expect(allSQL.contains("users.old_name"))
        #expect(allSQL.contains("new_name"))
        #expect(allSQL.contains("COLUMN"))
    }

    @Test("Modify column type uses ALTER COLUMN syntax")
    func modifyColumnTypeUsesAlterColumn() throws {
        let generator = makeGenerator()
        let old = makeColumn(name: "email", dataType: "VARCHAR(100)")
        let new = makeColumn(name: "email", dataType: "TEXT")
        let statements = try generator.generate(changes: [.modifyColumn(old: old, new: new)])

        let allSQL = statements.map { $0.sql }.joined(separator: "\n")
        #expect(allSQL.contains("ALTER TABLE [users] ALTER COLUMN [email]"))
        #expect(allSQL.contains("TEXT"))
    }

    @Test("Modify column nullability uses ALTER COLUMN")
    func modifyColumnNullabilityUsesAlterColumn() throws {
        let generator = makeGenerator()
        let old = makeColumn(name: "email", dataType: "NVARCHAR(255)", isNullable: false)
        let new = makeColumn(name: "email", dataType: "NVARCHAR(255)", isNullable: true)
        let statements = try generator.generate(changes: [.modifyColumn(old: old, new: new)])

        let allSQL = statements.map { $0.sql }.joined(separator: "\n")
        #expect(allSQL.contains("ALTER COLUMN"))
    }

    @Test("Drop column uses DROP COLUMN with bracket-quoted name")
    func dropColumn() throws {
        let generator = makeGenerator()
        let column = makeColumn(name: "email")
        let statements = try generator.generate(changes: [.deleteColumn(column)])

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("ALTER TABLE [users] DROP COLUMN [email]"))
        #expect(statements[0].isDestructive == true)
    }

    // MARK: - Index Tests

    @Test("Add index generates CREATE INDEX with bracket quoting")
    func addIndex() throws {
        let generator = makeGenerator()
        let index = makeIndex(name: "idx_name", columns: ["col"])
        let statements = try generator.generate(changes: [.addIndex(index)])

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("CREATE INDEX [idx_name] ON [users] ([col])"))
    }

    @Test("Add unique index generates CREATE UNIQUE INDEX")
    func addUniqueIndex() throws {
        let generator = makeGenerator()
        let index = makeIndex(name: "idx_name", columns: ["col"], isUnique: true)
        let statements = try generator.generate(changes: [.addIndex(index)])

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("CREATE UNIQUE INDEX [idx_name] ON [users] ([col])"))
    }

    @Test("Drop index uses DROP INDEX with ON clause for MSSQL")
    func dropIndex() throws {
        let generator = makeGenerator()
        let index = makeIndex(name: "idx_name")
        let statements = try generator.generate(changes: [.deleteIndex(index)])

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("DROP INDEX [idx_name] ON [users]"))
    }

    // MARK: - Foreign Key Tests

    @Test("Add foreign key contains ADD CONSTRAINT with bracket-quoted name")
    func addForeignKey() throws {
        let generator = makeGenerator()
        let fk = makeFK(name: "fk_user_role", columns: ["role_id"], refTable: "roles", refColumns: ["id"])
        let statements = try generator.generate(changes: [.addForeignKey(fk)])

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("ADD CONSTRAINT [fk_user_role]"))
        #expect(sql.contains("FOREIGN KEY"))
        #expect(sql.contains("[role_id]"))
        #expect(sql.contains("[roles]"))
        #expect(sql.contains("[id]"))
    }

    @Test("Drop foreign key uses DROP CONSTRAINT for MSSQL")
    func dropForeignKey() throws {
        let generator = makeGenerator()
        let fk = makeFK(name: "fk_user_role")
        let statements = try generator.generate(changes: [.deleteForeignKey(fk)])

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("ALTER TABLE [users] DROP CONSTRAINT [fk_user_role]"))
    }

    // MARK: - Primary Key Tests

    @Test("Modify primary key uses DROP CONSTRAINT and ADD PRIMARY KEY")
    func modifyPrimaryKey() throws {
        let generator = makeGenerator(pkConstraint: "PK_users")
        let statements = try generator.generate(changes: [.modifyPrimaryKey(old: ["id"], new: ["id", "tenant_id"])])

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("DROP CONSTRAINT"))
        #expect(sql.contains("ADD PRIMARY KEY"))
        #expect(sql.contains("[id]"))
        #expect(sql.contains("[tenant_id]"))
    }

    @Test("Modify primary key with no constraint name falls back to PK underscore tableName")
    func modifyPrimaryKeyDefaultConstraintName() throws {
        let generator = makeGenerator(table: "orders")
        let statements = try generator.generate(changes: [.modifyPrimaryKey(old: ["id"], new: ["order_id"])])

        #expect(statements.count == 1)
        let sql = statements[0].sql
        #expect(sql.contains("DROP CONSTRAINT"))
        #expect(sql.contains("PK_orders"))
    }

    // MARK: - Statement Validity Tests

    @Test("All generated statements end with semicolon")
    func allStatementsEndWithSemicolon() throws {
        let generator = makeGenerator()
        let column = makeColumn(name: "field1")
        let index = makeIndex(name: "idx_field1", columns: ["field1"])
        let changes: [SchemaChange] = [
            .addColumn(column),
            .addIndex(index)
        ]
        let statements = try generator.generate(changes: changes)

        for statement in statements {
            #expect(statement.sql.hasSuffix(";"))
        }
    }

    @Test("Add column is not destructive")
    func addColumnNotDestructive() throws {
        let generator = makeGenerator()
        let column = makeColumn(name: "new_field")
        let statements = try generator.generate(changes: [.addColumn(column)])

        #expect(statements[0].isDestructive == false)
    }
}
