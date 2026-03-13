//
//  TypePickerContentView.swift
//  TablePro
//
//  Searchable type picker for structure view column type editing.
//

import SwiftUI

/// Data type categories for type picker
enum DataTypeCategory: String, CaseIterable {
    case numeric = "Numeric"
    case string = "String"
    case dateTime = "Date & Time"
    case binary = "Binary"
    case other = "Other"

    func types(for dbType: DatabaseType) -> [String] {
        Self.typeMap[self]?[dbType] ?? []
    }

    // swiftlint:disable:next line_length
    private static let typeMap: [DataTypeCategory: [DatabaseType: [String]]] = [
        .numeric: [
            .mysql: ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "BIGINT", "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "BIT"],
            .mariadb: ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "BIGINT", "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "BIT"],
            .postgresql: ["SMALLINT", "INTEGER", "BIGINT", "DECIMAL", "NUMERIC", "REAL", "DOUBLE PRECISION", "SMALLSERIAL", "SERIAL", "BIGSERIAL"],
            .redshift: ["SMALLINT", "INTEGER", "BIGINT", "DECIMAL", "NUMERIC", "REAL", "DOUBLE PRECISION", "SMALLSERIAL", "SERIAL", "BIGSERIAL"],
            .mssql: ["TINYINT", "SMALLINT", "INT", "BIGINT", "DECIMAL", "NUMERIC", "FLOAT", "REAL", "MONEY", "SMALLMONEY", "BIT"],
            .oracle: ["NUMBER", "BINARY_FLOAT", "BINARY_DOUBLE", "INTEGER", "SMALLINT", "FLOAT"],
            .clickhouse: [
                "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "UInt256",
                "Int8", "Int16", "Int32", "Int64", "Int128", "Int256",
                "Float32", "Float64", "Decimal", "Decimal32", "Decimal64", "Decimal128", "Decimal256", "Bool",
            ],
            .sqlite: ["INTEGER", "REAL", "NUMERIC"],
            .duckdb: ["INTEGER", "BIGINT", "HUGEINT", "SMALLINT", "TINYINT", "DOUBLE", "FLOAT", "DECIMAL", "REAL", "NUMERIC"],
            .mongodb: ["Int32", "Int64", "Double", "Decimal128"],
            .redis: ["Integer"],
        ],
        .string: [
            .mysql: ["CHAR", "VARCHAR", "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT"],
            .mariadb: ["CHAR", "VARCHAR", "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT"],
            .postgresql: ["CHAR", "VARCHAR", "TEXT"],
            .redshift: ["CHAR", "VARCHAR", "TEXT"],
            .mssql: ["CHAR", "VARCHAR", "NCHAR", "NVARCHAR", "TEXT", "NTEXT"],
            .oracle: ["CHAR", "VARCHAR2", "NCHAR", "NVARCHAR2", "CLOB", "NCLOB", "LONG"],
            .clickhouse: ["String", "FixedString", "UUID", "IPv4", "IPv6"],
            .sqlite: ["TEXT"],
            .duckdb: ["VARCHAR", "TEXT", "CHAR", "BPCHAR"],
            .mongodb: ["String", "ObjectId", "UUID"],
            .redis: ["String"],
        ],
        .dateTime: [
            .mysql: ["DATE", "TIME", "DATETIME", "TIMESTAMP", "YEAR"],
            .mariadb: ["DATE", "TIME", "DATETIME", "TIMESTAMP", "YEAR"],
            .postgresql: ["DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL"],
            .redshift: ["DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL"],
            .mssql: ["DATE", "TIME", "DATETIME", "DATETIME2", "SMALLDATETIME", "DATETIMEOFFSET"],
            .oracle: ["DATE", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "TIMESTAMP WITH LOCAL TIME ZONE", "INTERVAL YEAR TO MONTH", "INTERVAL DAY TO SECOND"],
            .clickhouse: ["Date", "Date32", "DateTime", "DateTime64"],
            .sqlite: ["DATE", "DATETIME"],
            .duckdb: ["DATE", "TIME", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "INTERVAL"],
            .mongodb: ["Date", "Timestamp"],
        ],
        .binary: [
            .mysql: ["BINARY", "VARBINARY", "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB"],
            .mariadb: ["BINARY", "VARBINARY", "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB"],
            .postgresql: ["BYTEA"],
            .redshift: ["BYTEA"],
            .mssql: ["BINARY", "VARBINARY", "IMAGE"],
            .oracle: ["BLOB", "RAW", "LONG RAW", "BFILE"],
            .sqlite: ["BLOB"],
            .duckdb: ["BLOB", "BYTEA"],
            .mongodb: ["BinData"],
        ],
        .other: [
            .mysql: ["BOOLEAN", "ENUM", "SET", "JSON"],
            .mariadb: ["BOOLEAN", "ENUM", "SET", "JSON"],
            .postgresql: ["BOOLEAN", "UUID", "JSON", "JSONB", "ARRAY", "HSTORE", "INET", "CIDR", "MACADDR", "TSVECTOR", "TSQUERY"],
            .redshift: ["BOOLEAN", "UUID", "JSON", "JSONB", "ARRAY", "HSTORE", "INET", "CIDR", "MACADDR", "TSVECTOR", "TSQUERY"],
            .mssql: ["BIT", "UNIQUEIDENTIFIER", "XML", "SQL_VARIANT", "ROWVERSION", "HIERARCHYID"],
            .oracle: ["BOOLEAN", "ROWID", "UROWID", "XMLTYPE", "SDO_GEOMETRY"],
            .clickhouse: ["Array", "Tuple", "Map", "Nested", "JSON", "Nullable", "LowCardinality", "Enum8", "Enum16", "Nothing"],
            .sqlite: ["BOOLEAN"],
            .duckdb: ["BOOLEAN", "UUID", "JSON", "LIST", "MAP", "STRUCT", "ENUM", "BIT", "UNION"],
            .mongodb: ["Boolean", "Object", "Array", "Null", "Regex"],
            .redis: ["List", "Set", "Sorted Set", "Hash", "Stream"],
        ],
    ]
}

struct TypePickerContentView: View {
    let databaseType: DatabaseType
    let currentValue: String
    let onCommit: (String) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    private static let rowHeight: CGFloat = 22
    private static let sectionHeaderHeight: CGFloat = 28
    private static let searchAreaHeight: CGFloat = 44
    private static let maxTotalHeight: CGFloat = 360

    private var visibleCategories: [DataTypeCategory] {
        DataTypeCategory.allCases.filter { !filteredTypes(for: $0).isEmpty }
    }

    private func filteredTypes(for category: DataTypeCategory) -> [String] {
        let types = category.types(for: databaseType)
        if searchText.isEmpty { return types }
        let query = searchText.lowercased()
        return types.filter { $0.lowercased().contains(query) }
    }

    private var totalFilteredCount: Int {
        visibleCategories.reduce(0) { $0 + filteredTypes(for: $1).count }
    }

    private var listHeight: CGFloat {
        let contentHeight = CGFloat(totalFilteredCount) * Self.rowHeight
            + CGFloat(visibleCategories.count) * Self.sectionHeaderHeight
            + 8
        return min(contentHeight, Self.maxTotalHeight - Self.searchAreaHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search or type...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .onSubmit { commitFreeform() }

            Divider()

            List {
                ForEach(visibleCategories, id: \.self) { category in
                    Section(header: Text(category.rawValue)) {
                        ForEach(filteredTypes(for: category), id: \.self) { type in
                            typeRow(type)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { commitType(type) }
                                .listRowInsets(EdgeInsets(
                                    top: 2, leading: 6, bottom: 2, trailing: 6
                                ))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: listHeight)
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private func typeRow(_ type: String) -> some View {
        if type.caseInsensitiveCompare(currentValue) == .orderedSame {
            Text(type)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tint)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(type)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func commitFreeform() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        onCommit(text)
        onDismiss()
    }

    private func commitType(_ type: String) {
        onCommit(type)
        onDismiss()
    }
}
