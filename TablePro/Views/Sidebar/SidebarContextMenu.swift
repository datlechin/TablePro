//
//  SidebarContextMenu.swift
//  TablePro
//
//  Context menu for sidebar table rows and empty space.
//

import SwiftUI

/// Unified context menu for sidebar — used for both table rows and empty space
struct SidebarContextMenu: View {
    let clickedTable: TableInfo?
    @Binding var selectedTables: Set<TableInfo>
    let isReadOnly: Bool
    let onBatchToggleTruncate: () -> Void
    let onBatchToggleDelete: () -> Void

    private var hasSelection: Bool {
        !selectedTables.isEmpty || clickedTable != nil
    }

    private var isView: Bool {
        clickedTable?.type == .view
    }

    var body: some View {
        Button("Create New Table...") {
            NotificationCenter.default.post(name: .createTable, object: nil)
        }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(isReadOnly)

        Button("Create New View...") {
            NotificationCenter.default.post(name: .createView, object: nil)
        }
        .disabled(isReadOnly)

        Divider()

        if isView {
            Button("Edit View Definition") {
                if let viewName = clickedTable?.name {
                    NotificationCenter.default.post(
                        name: .editViewDefinition,
                        object: viewName
                    )
                }
            }
            .disabled(isReadOnly)
        }

        Button("Show Structure") {
            if let tableName = clickedTable?.name {
                NotificationCenter.default.post(
                    name: .showTableStructure,
                    object: tableName
                )
            }
        }
        .disabled(clickedTable == nil)

        Button("Copy Name") {
            let names: [String]
            if selectedTables.isEmpty, let table = clickedTable {
                names = [table.name]
            } else {
                names = selectedTables.map { $0.name }.sorted()
            }
            ClipboardService.shared.writeText(names.joined(separator: ","))
        }
        .keyboardShortcut("c", modifiers: .command)
        .disabled(!hasSelection)

        Button("Export...") {
            if selectedTables.isEmpty, let table = clickedTable {
                selectedTables.insert(table)
            }
            NotificationCenter.default.post(name: .exportTables, object: nil)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!hasSelection)

        if !isView {
            Button("Import...") {
                NotificationCenter.default.post(name: .importTables, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(isReadOnly)
        }

        Divider()

        if !isView {
            Button("Truncate") {
                if selectedTables.isEmpty, let table = clickedTable {
                    selectedTables.insert(table)
                }
                onBatchToggleTruncate()
            }
            .disabled(!hasSelection || isReadOnly)
        }

        Button(
            isView ? String(localized: "Drop View") : String(localized: "Delete"),
            role: .destructive
        ) {
            if selectedTables.isEmpty, let table = clickedTable {
                selectedTables.insert(table)
            }
            onBatchToggleDelete()
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(!hasSelection || isReadOnly)
    }
}
