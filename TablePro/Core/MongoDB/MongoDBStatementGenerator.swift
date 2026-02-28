//
//  MongoDBStatementGenerator.swift
//  TablePro
//
//  Generates MongoDB shell commands (insertOne, replaceOne, deleteOne) from tracked changes.
//  Parallel to SQLStatementGenerator for SQL databases.
//

import Foundation
import os

struct MongoDBStatementGenerator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MongoDBStatementGenerator")

    let collectionName: String
    let columns: [String]

    /// Index of "_id" field in the columns array (used as primary key equivalent)
    var idColumnIndex: Int? {
        columns.firstIndex(of: "_id")
    }

    // MARK: - Public API

    /// Generate MongoDB shell statements from changes
    func generateStatements(
        from changes: [RowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [ParameterizedStatement] {
        var statements: [ParameterizedStatement] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                if let stmt = generateInsert(for: change, insertedRowData: insertedRowData) {
                    statements.append(stmt)
                }
            case .update:
                if let stmt = generateUpdate(for: change) {
                    statements.append(stmt)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                if let stmt = generateDelete(for: change) {
                    statements.append(stmt)
                }
            }
        }

        return statements
    }

    // MARK: - INSERT

    private func generateInsert(
        for change: RowChange,
        insertedRowData: [Int: [String?]]
    ) -> ParameterizedStatement? {
        var doc: [String: String] = [:]

        if let values = insertedRowData[change.rowIndex] {
            for (index, value) in values.enumerated() {
                guard index < columns.count else { continue }
                let column = columns[index]
                // Skip _id for inserts (let MongoDB auto-generate)
                if column == "_id" { continue }
                // Skip DEFAULT sentinel
                if value == "__DEFAULT__" { continue }
                if let val = value {
                    doc[column] = val
                }
            }
        } else {
            // Fallback: use cellChanges
            for cellChange in change.cellChanges {
                if cellChange.columnName == "_id" { continue }
                if cellChange.newValue == "__DEFAULT__" { continue }
                if let val = cellChange.newValue {
                    doc[cellChange.columnName] = val
                }
            }
        }

        guard !doc.isEmpty else { return nil }

        let docJson = serializeDocument(doc)
        let shell = "db.\(collectionName).insertOne(\(docJson))"
        return ParameterizedStatement(sql: shell, parameters: [])
    }

    // MARK: - UPDATE (updateOne with $set)

    private func generateUpdate(for change: RowChange) -> ParameterizedStatement? {
        guard !change.cellChanges.isEmpty else { return nil }

        // Get _id value for the filter
        guard let idIndex = idColumnIndex,
              let originalRow = change.originalRow,
              idIndex < originalRow.count,
              let idValue = originalRow[idIndex] else {
            Self.logger.warning("Skipping UPDATE for collection '\(self.collectionName)' - no _id value")
            return nil
        }

        // Build $set document with only changed fields
        var setDoc: [String: String] = [:]
        for cellChange in change.cellChanges {
            if cellChange.columnName == "_id" { continue }
            if let val = cellChange.newValue {
                setDoc[cellChange.columnName] = val
            } else {
                setDoc[cellChange.columnName] = "null"
            }
        }

        guard !setDoc.isEmpty else { return nil }

        let filterJson = buildIdFilter(idValue)
        let setJson = serializeDocument(setDoc)
        let shell = "db.\(collectionName).updateOne(\(filterJson), {\"$set\": \(setJson)})"
        return ParameterizedStatement(sql: shell, parameters: [])
    }

    // MARK: - DELETE

    private func generateDelete(for change: RowChange) -> ParameterizedStatement? {
        guard let originalRow = change.originalRow else { return nil }

        // Try to use _id first
        if let idIndex = idColumnIndex,
           idIndex < originalRow.count,
           let idValue = originalRow[idIndex] {
            let filterJson = buildIdFilter(idValue)
            let shell = "db.\(collectionName).deleteOne(\(filterJson))"
            return ParameterizedStatement(sql: shell, parameters: [])
        }

        // Fallback: match all fields
        var filter: [String: String] = [:]
        for (index, column) in columns.enumerated() {
            guard index < originalRow.count else { continue }
            if let value = originalRow[index] {
                filter[column] = value
            }
        }

        guard !filter.isEmpty else { return nil }

        let filterJson = serializeDocument(filter)
        let shell = "db.\(collectionName).deleteOne(\(filterJson))"
        return ParameterizedStatement(sql: shell, parameters: [])
    }

    // MARK: - Helpers

    /// Build a filter document for an _id value.
    /// Handles ObjectId format: if the value looks like a 24-char hex string, wrap in ObjectId()
    private func buildIdFilter(_ idValue: String) -> String {
        if isObjectIdString(idValue) {
            return "{\"_id\": {\"$oid\": \"\(idValue)\"}}"
        }
        // Try as number
        if Int64(idValue) != nil {
            return "{\"_id\": \(idValue)}"
        }
        // String _id
        return "{\"_id\": \"\(escapeJsonString(idValue))\"}"
    }

    /// Check if a string looks like a MongoDB ObjectId (24 hex characters)
    private func isObjectIdString(_ value: String) -> Bool {
        let nsValue = value as NSString
        return nsValue.length == 24 && value.allSatisfy { $0.isHexDigit }
    }

    /// Serialize a [String: String] dictionary to JSON-like format
    private func serializeDocument(_ doc: [String: String]) -> String {
        let entries = doc.sorted { $0.key < $1.key }.map { key, value in
            let jsonValue = jsonValue(for: value)
            return "\"\(escapeJsonString(key))\": \(jsonValue)"
        }
        return "{\(entries.joined(separator: ", "))}"
    }

    /// Convert a string value to its JSON representation (auto-detect type)
    private func jsonValue(for value: String) -> String {
        if value == "true" || value == "false" {
            return value
        }
        if value == "null" {
            return "null"
        }
        if Int64(value) != nil {
            return value
        }
        if Double(value) != nil, value.contains(".") {
            return value
        }
        // JSON object or array
        if (value.hasPrefix("{") && value.hasSuffix("}")) ||
            (value.hasPrefix("[") && value.hasSuffix("]")) {
            return value
        }
        return "\"\(escapeJsonString(value))\""
    }

    /// Escape special characters for JSON strings
    private func escapeJsonString(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
