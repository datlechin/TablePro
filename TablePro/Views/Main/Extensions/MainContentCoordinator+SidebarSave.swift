//
//  MainContentCoordinator+SidebarSave.swift
//  TablePro
//
//  Sidebar save logic extracted from MainContentView.
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    // MARK: - Sidebar Save

    func saveSidebarEdits(
        selectedRowIndices: Set<Int>,
        editState: MultiRowEditState
    ) async throws {
        guard let tab = tabManager.selectedTab,
            !selectedRowIndices.isEmpty,
            let tableName = tab.tableName
        else {
            return
        }

        let editedFields = editState.getEditedFields()
        guard !editedFields.isEmpty else { return }

        if connection.type == .redis {
            var redisStatements: [ParameterizedStatement] = []
            for rowIndex in selectedRowIndices.sorted() {
                guard rowIndex < tab.resultRows.count else { continue }
                let row = tab.resultRows[rowIndex]
                let commands = generateSidebarRedisCommands(
                    originalRow: row.values,
                    editedFields: editedFields,
                    columns: tab.resultColumns
                )
                redisStatements += commands.map { ParameterizedStatement(sql: $0, parameters: []) }
            }
            guard !redisStatements.isEmpty else { return }
            try await executeSidebarChanges(statements: redisStatements)
        } else {
            let generator = SQLStatementGenerator(
                tableName: tableName,
                columns: tab.resultColumns,
                primaryKeyColumn: changeManager.primaryKeyColumn,
                databaseType: connection.type,
                quoteIdentifier: changeManager.pluginDriver?.quoteIdentifier
            )

            var statements: [ParameterizedStatement] = []
            for rowIndex in selectedRowIndices.sorted() {
                guard rowIndex < tab.resultRows.count else { continue }
                let originalRow = tab.resultRows[rowIndex].values

                let cellChanges = editedFields.map { field in
                    CellChange(
                        rowIndex: rowIndex,
                        columnIndex: field.columnIndex,
                        columnName: field.columnName,
                        oldValue: originalRow[field.columnIndex],
                        newValue: field.newValue
                    )
                }
                let change = RowChange(
                    rowIndex: rowIndex,
                    type: .update,
                    cellChanges: cellChanges,
                    originalRow: originalRow
                )

                if let stmt = generator.generateUpdateSQL(for: change) {
                    statements.append(stmt)
                }
            }
            guard !statements.isEmpty else { return }
            try await executeSidebarChanges(statements: statements)
        }

        runQuery()
    }

    private func generateSidebarRedisCommands(
        originalRow: [String?],
        editedFields: [(columnIndex: Int, columnName: String, newValue: String?)],
        columns: [String]
    ) -> [String] {
        guard let keyIndex = columns.firstIndex(of: "Key"),
            keyIndex < originalRow.count,
            let originalKey = originalRow[keyIndex]
        else {
            return []
        }

        var commands: [String] = []
        var effectiveKey = originalKey

        for field in editedFields {
            switch field.columnName {
            case "Key":
                if let newKey = field.newValue, newKey != originalKey {
                    commands.append("RENAME \(redisEscape(originalKey)) \(redisEscape(newKey))")
                    effectiveKey = newKey
                }
            case "Value":
                if let newValue = field.newValue {
                    // Only use SET for string-type keys — other types need specific commands
                    let typeIndex = columns.firstIndex(of: "Type")
                    let keyType = typeIndex.flatMap {
                        $0 < originalRow.count ? originalRow[$0]?.uppercased() : nil
                    }
                    if keyType == nil || keyType == "STRING" || keyType == "NONE" {
                        commands.append("SET \(redisEscape(effectiveKey)) \(redisEscape(newValue))")
                    }
                    // Non-string types: skip (editing Value for complex types not supported via sidebar)
                }
            case "TTL":
                if let ttlStr = field.newValue, let ttl = Int(ttlStr), ttl >= 0 {
                    commands.append("EXPIRE \(redisEscape(effectiveKey)) \(ttl)")
                } else if field.newValue == nil || field.newValue == "-1" {
                    commands.append("PERSIST \(redisEscape(effectiveKey))")
                }
            default:
                break
            }
        }

        return commands
    }

    private func redisEscape(_ value: String) -> String {
        let needsQuoting =
            value.isEmpty || value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
        if needsQuoting {
            let escaped =
                value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\"\(escaped)\""
        }
        return value
    }
}
