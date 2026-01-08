//
//  TableCreationModels.swift
//  TablePro
//
//  Models for creating new tables
//

import Foundation

/// Foreign key constraint definition
struct ForeignKeyConstraint: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String  // Constraint name (optional, auto-generated if empty)
    var columns: [String]  // Local column(s)
    var referencedTable: String
    var referencedColumns: [String]
    var onDelete: ReferentialAction = .noAction
    var onUpdate: ReferentialAction = .noAction

    init(
        id: UUID = UUID(),
        name: String = "",
        columns: [String] = [],
        referencedTable: String = "",
        referencedColumns: [String] = [],
        onDelete: ReferentialAction = .noAction,
        onUpdate: ReferentialAction = .noAction
    ) {
        self.id = id
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }

    var isValid: Bool {
        !columns.isEmpty && !referencedTable.isEmpty && !referencedColumns.isEmpty
    }
}

/// Referential action for foreign keys
enum ReferentialAction: String, CaseIterable, Codable {
    case noAction = "NO ACTION"
    case cascade = "CASCADE"
    case setNull = "SET NULL"
    case setDefault = "SET DEFAULT"
    case restrict = "RESTRICT"
}

/// Index definition
struct IndexDefinition: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var columns: [String]
    var isUnique: Bool = false
    var type: IndexType = .btree

    init(
        id: UUID = UUID(),
        name: String = "",
        columns: [String] = [],
        isUnique: Bool = false,
        type: IndexType = .btree
    ) {
        self.id = id
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.type = type
    }

    var isValid: Bool {
        !name.isEmpty && !columns.isEmpty
    }
}

/// Index type
enum IndexType: String, CaseIterable, Codable {
    case btree = "BTREE"
    case hash = "HASH"
    case gist = "GIST"  // PostgreSQL only
    case gin = "GIN"    // PostgreSQL only
}

/// Check constraint definition
struct CheckConstraint: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var expression: String

    init(
        id: UUID = UUID(),
        name: String = "",
        expression: String = ""
    ) {
        self.id = id
        self.name = name
        self.expression = expression
    }

    var isValid: Bool {
        !name.isEmpty && !expression.isEmpty
    }
}

/// Complete options for creating a table
struct TableCreationOptions: Equatable, Codable {
    var tableName: String = ""
    var databaseName: String = ""  // Schema for PostgreSQL, database for MySQL, unused for SQLite
    var columns: [ColumnDefinition] = []
    var primaryKeyColumns: [String] = []
    var foreignKeys: [ForeignKeyConstraint] = []
    var indexes: [IndexDefinition] = []
    var checkConstraints: [CheckConstraint] = []

    // MySQL/MariaDB specific (in Advanced Options)
    var engine: String? = "InnoDB"
    var charset: String? = "utf8mb4"
    var collation: String? = "utf8mb4_unicode_ci"
    var comment: String? = ""

    // PostgreSQL specific (in Advanced Options)
    var tablespace: String? = ""

    var isValid: Bool {
        !tableName.isEmpty &&
            !columns.isEmpty &&
            columns.allSatisfy { $0.isValid } &&
            Set(columns.map { $0.name.lowercased() }).count == columns.count
    }

    var hasPrimaryKey: Bool {
        !primaryKeyColumns.isEmpty
    }
}

/// Definition of a single column
struct ColumnDefinition: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var dataType: String
    var length: Int?
    var precision: Int?
    var notNull: Bool = false
    var defaultValue: String?
    var autoIncrement: Bool = false
    var unsigned: Bool = false  // MySQL only
    var zerofill: Bool = false  // MySQL only
    var comment: String?

    init(
        id: UUID = UUID(),
        name: String = "",
        dataType: String = "INT",
        length: Int? = nil,
        precision: Int? = nil,
        notNull: Bool = false,
        defaultValue: String? = nil,
        autoIncrement: Bool = false,
        unsigned: Bool = false,
        zerofill: Bool = false,
        comment: String? = nil
    ) {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.length = length
        self.precision = precision
        self.notNull = notNull
        self.defaultValue = defaultValue
        self.autoIncrement = autoIncrement
        self.unsigned = unsigned
        self.zerofill = zerofill
        self.comment = comment
    }

    var isValid: Bool {
        !name.isEmpty && !dataType.isEmpty
    }

    var fullDataType: String {
        var type = dataType.uppercased()
        if let len = length {
            if let prec = precision {
                type += "(\(len),\(prec))"
            } else {
                type += "(\(len))"
            }
        }
        return type
    }

    func needsLength(for dbType: DatabaseType) -> Bool {
        let typeUpper = dataType.uppercased()
        return typeUpper.contains("VARCHAR") ||
            typeUpper.contains("CHAR") ||
            typeUpper == "VARBINARY" ||
            typeUpper == "BINARY"
    }

    func supportsAutoIncrement(for dbType: DatabaseType) -> Bool {
        let typeUpper = dataType.uppercased()
        let integerTypes = ["INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT"]
        return integerTypes.contains { typeUpper.contains($0) }
    }
}

/// Common column templates
enum ColumnTemplate: String, CaseIterable, Identifiable {
    case id = "ID (Auto Increment)"
    case uuid = "UUID"
    case name = "Name (VARCHAR)"
    case email = "Email"
    case description = "Description (TEXT)"
    case createdAt = "Created At"
    case updatedAt = "Updated At"
    case isActive = "Is Active (BOOLEAN)"

    var id: String { rawValue }

    func createColumn(for dbType: DatabaseType) -> ColumnDefinition {
        switch self {
        case .id:
            return ColumnDefinition(
                name: "id",
                dataType: "INT",
                notNull: true,
                autoIncrement: true
            )
        case .uuid:
            return ColumnDefinition(
                name: "id",
                dataType: dbType == .postgresql ? "UUID" : "VARCHAR",
                length: dbType == .postgresql ? nil : 36,
                notNull: true
            )
        case .name:
            return ColumnDefinition(
                name: "name",
                dataType: "VARCHAR",
                length: 255,
                notNull: true,
                defaultValue: "''"
            )
        case .email:
            return ColumnDefinition(
                name: "email",
                dataType: "VARCHAR",
                length: 255,
                notNull: true
            )
        case .description:
            return ColumnDefinition(
                name: "description",
                dataType: "TEXT",
                notNull: false
            )
        case .createdAt:
            return ColumnDefinition(
                name: "created_at",
                dataType: "TIMESTAMP",
                notNull: true,
                defaultValue: dbType == .postgresql ? "CURRENT_TIMESTAMP" : "NOW()"
            )
        case .updatedAt:
            return ColumnDefinition(
                name: "updated_at",
                dataType: "TIMESTAMP",
                notNull: true,
                defaultValue: dbType == .postgresql ? "CURRENT_TIMESTAMP" : "NOW()"
            )
        case .isActive:
            return ColumnDefinition(
                name: "is_active",
                dataType: dbType == .postgresql ? "BOOLEAN" : "TINYINT",
                length: dbType == .postgresql ? nil : 1,
                notNull: true,
                defaultValue: dbType == .postgresql ? "TRUE" : "1"
            )
        }
    }
}

/// Data type categories for picker
enum DataTypeCategory: String, CaseIterable {
    case numeric = "Numeric"
    case string = "String"
    case dateTime = "Date & Time"
    case binary = "Binary"
    case other = "Other"

    func types(for dbType: DatabaseType) -> [String] {
        switch self {
        case .numeric:
            var types = ["INT", "BIGINT", "SMALLINT", "DECIMAL", "FLOAT", "DOUBLE"]
            if dbType == .mysql || dbType == .mariadb {
                types.append(contentsOf: ["TINYINT", "MEDIUMINT"])
            }
            if dbType == .postgresql {
                types.append(contentsOf: ["SERIAL", "BIGSERIAL"])
            }
            return types
        case .string:
            var types = ["VARCHAR", "CHAR", "TEXT"]
            if dbType == .mysql || dbType == .mariadb {
                types.append(contentsOf: ["MEDIUMTEXT", "LONGTEXT", "TINYTEXT"])
            }
            return types
        case .dateTime:
            var types = ["DATE", "TIME", "DATETIME", "TIMESTAMP"]
            if dbType == .mysql || dbType == .mariadb {
                types.append("YEAR")
            }
            return types
        case .binary:
            return ["BLOB", "BINARY", "VARBINARY"]
        case .other:
            var types = ["BOOLEAN", "JSON"]
            if dbType == .postgresql {
                types.append(contentsOf: ["JSONB", "UUID"])
            }
            if dbType == .mysql || dbType == .mariadb {
                types.append(contentsOf: ["ENUM", "SET"])
            }
            return types
        }
    }
}
