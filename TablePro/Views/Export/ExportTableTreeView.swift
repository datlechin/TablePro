//
//  ExportTableTreeView.swift
//  TablePro
//
//  Tree view for selecting tables to export.
//  Shows database hierarchy with checkbox selection.
//  When SQL format is selected, displays additional columns for Structure, Drop, and Data options.
//

import SwiftUI

/// Tree view for selecting tables to export
struct ExportTableTreeView: View {
    @Binding var databaseItems: [ExportDatabaseItem]
    let format: ExportFormat

    var body: some View {
        List {
            ForEach($databaseItems) { $database in
                DisclosureGroup(isExpanded: $database.isExpanded) {
                    ForEach($database.tables) { $table in
                        tableRow(table: $table)
                    }
                } label: {
                    databaseRow(database: $database)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Database Row

    private func databaseRow(database: Binding<ExportDatabaseItem>) -> some View {
        HStack(spacing: 8) {
            // Native tristate checkbox using sources binding
            Toggle(sources: database.tables, isOn: \.isSelected) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            // Database icon
            Image(systemName: "cylinder")
                .foregroundStyle(.blue)
                .font(.system(size: 12))

            // Database name
            Text(database.wrappedValue.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // SQL-specific checkboxes placeholder (hidden for database row)
            if format == .sql {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 56)
                    Color.clear.frame(width: 44)
                    Color.clear.frame(width: 44)
                }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Table Row

    private func tableRow(table: Binding<ExportTableItem>) -> some View {
        HStack(spacing: 8) {
            // Selection checkbox
            Toggle("", isOn: table.isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()

            // Table icon
            Image(systemName: table.wrappedValue.type == .view ? "eye" : "tablecells")
                .foregroundStyle(table.wrappedValue.type == .view ? .purple : .secondary)
                .font(.system(size: 12))

            // Table name
            Text(table.wrappedValue.name)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // SQL-specific checkboxes
            if format == .sql {
                HStack(spacing: 0) {
                    // Structure checkbox
                    Toggle("", isOn: table.sqlOptions.includeStructure)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .frame(width: 56, alignment: .center)
                        .disabled(!table.wrappedValue.isSelected)

                    // Drop checkbox
                    Toggle("", isOn: table.sqlOptions.includeDrop)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .frame(width: 44, alignment: .center)
                        .disabled(!table.wrappedValue.isSelected)

                    // Data checkbox
                    Toggle("", isOn: table.sqlOptions.includeData)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .frame(width: 44, alignment: .center)
                        .disabled(!table.wrappedValue.isSelected)
                }
                .opacity(table.wrappedValue.isSelected ? 1.0 : 0.4)
            }
        }
    }

}

// MARK: - Preview

#Preview("CSV Format") {
    let tables = [
        ExportTableItem(name: "users", type: .table, isSelected: true),
        ExportTableItem(name: "posts", type: .table, isSelected: false),
        ExportTableItem(name: "comments", type: .table, isSelected: true),
        ExportTableItem(name: "user_stats", type: .view, isSelected: false)
    ]

    return ExportTableTreeView(
        databaseItems: .constant([
            ExportDatabaseItem(name: "my_database", tables: tables)
        ]),
        format: .csv
    )
    .frame(width: 240, height: 400)
}

#Preview("SQL Format") {
    let tables = [
        ExportTableItem(name: "users", type: .table, isSelected: true),
        ExportTableItem(name: "posts", type: .table, isSelected: false),
        ExportTableItem(name: "comments", type: .table, isSelected: true),
        ExportTableItem(name: "user_stats", type: .view, isSelected: false)
    ]

    return ExportTableTreeView(
        databaseItems: .constant([
            ExportDatabaseItem(name: "my_database", tables: tables)
        ]),
        format: .sql
    )
    .frame(width: 380, height: 400)
}
