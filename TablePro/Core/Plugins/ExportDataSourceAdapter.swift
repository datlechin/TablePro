//
//  ExportDataSourceAdapter.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class ExportDataSourceAdapter: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String
    private let driver: DatabaseDriver
    private let dbType: DatabaseType

    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportDataSourceAdapter")

    init(driver: DatabaseDriver, databaseType: DatabaseType) {
        self.driver = driver
        self.dbType = databaseType
        self.databaseTypeId = databaseType.rawValue
    }

    func fetchRows(table: String, databaseName: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        let query: String
        switch dbType {
        case .mongodb:
            let escaped = escapeJSIdentifier(table)
            if escaped.hasPrefix("[") {
                query = "db\(escaped).find({})"
            } else {
                query = "db.\(escaped).find({})"
            }
        case .redis:
            query = "SCAN 0 MATCH \"*\" COUNT 10000"
        default:
            let tableRef = qualifiedTableRef(table: table, databaseName: databaseName)
            query = "SELECT * FROM \(tableRef)"
        }
        let result = try await driver.fetchRows(query: query, offset: offset, limit: limit)
        return mapToPluginResult(result)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await driver.fetchTableDDL(table: table)
    }

    func execute(query: String) async throws -> PluginQueryResult {
        let result = try await driver.execute(query: query)
        return mapToPluginResult(result)
    }

    func quoteIdentifier(_ identifier: String) -> String {
        driver.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        driver.escapeStringLiteral(value)
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        try await driver.fetchApproximateRowCount(table: table)
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        let sequences = try await driver.fetchDependentSequences(forTable: table)
        return sequences.map { PluginSequenceInfo(name: $0.name, ddl: $0.ddl) }
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        let types = try await driver.fetchDependentTypes(forTable: table)
        return types.map { PluginEnumTypeInfo(name: $0.name, labels: $0.labels) }
    }

    // MARK: - Helpers

    private func qualifiedTableRef(table: String, databaseName: String) -> String {
        if databaseName.isEmpty {
            return driver.quoteIdentifier(table)
        } else {
            let quotedDb = driver.quoteIdentifier(databaseName)
            let quotedTable = driver.quoteIdentifier(table)
            return "\(quotedDb).\(quotedTable)"
        }
    }

    private func escapeJSIdentifier(_ name: String) -> String {
        guard let firstChar = name.first,
              !firstChar.isNumber,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return "[\"\(PluginExportUtilities.escapeJSONString(name))\"]"
        }
        return name
    }

    private func mapToPluginResult(_ result: QueryResult) -> PluginQueryResult {
        PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypes.map { $0.rawType ?? "" },
            rows: result.rows,
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime
        )
    }
}
