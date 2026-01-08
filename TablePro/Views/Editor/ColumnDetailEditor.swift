//
//  ColumnDetailEditor.swift
//  TablePro
//
//  Detailed editor for a selected column.
//  Shows all properties with full editing capabilities.
//

import SwiftUI

struct ColumnDetailEditor: View {
    @Binding var column: ColumnDefinition
    let databaseType: DatabaseType

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.sm) {
            Text("Column Details")
                .font(.system(size: DesignConstants.FontSize.body, weight: .semibold))

            Form {
                // Column name
                TextField("Column Name", text: $column.name)
                    .textFieldStyle(.roundedBorder)

                // Data type picker
                HStack {
                    Text("Data Type:")
                        .frame(width: 100, alignment: .trailing)

                    DataTypePicker(
                        selectedType: $column.dataType,
                        databaseType: databaseType
                    )
                }

                // Length (for VARCHAR, CHAR, etc.)
                if column.needsLength(for: databaseType) {
                    HStack {
                        Text("Length:")
                            .frame(width: 100, alignment: .trailing)

                        TextField("Length", value: $column.length, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }

                // Precision/Scale (for DECIMAL, NUMERIC)
                if column.dataType.uppercased().contains("DECIMAL") ||
                    column.dataType.uppercased().contains("NUMERIC") {
                    HStack {
                        Text("Precision:")
                            .frame(width: 100, alignment: .trailing)

                        TextField("Precision", value: $column.length, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)

                        Text("Scale:")

                        TextField("Scale", value: $column.precision, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }

                // NOT NULL checkbox
                Toggle("NOT NULL", isOn: $column.notNull)
                    .toggleStyle(.checkbox)

                // Auto-increment (for integer types only)
                if column.supportsAutoIncrement(for: databaseType) {
                    Toggle("Auto Increment", isOn: $column.autoIncrement)
                        .toggleStyle(.checkbox)
                }

                // Unsigned (MySQL only)
                if (databaseType == .mysql || databaseType == .mariadb) &&
                    isNumericType(column.dataType) {
                    Toggle("Unsigned", isOn: $column.unsigned)
                        .toggleStyle(.checkbox)
                }

                // Zerofill (MySQL only)
                if (databaseType == .mysql || databaseType == .mariadb) &&
                    isNumericType(column.dataType) {
                    Toggle("Zero Fill", isOn: $column.zerofill)
                        .toggleStyle(.checkbox)
                }

                // Default value
                HStack {
                    Text("Default:")
                        .frame(width: 100, alignment: .trailing)

                    TextField("Default Value", text: Binding(
                        get: { column.defaultValue ?? "" },
                        set: { column.defaultValue = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                // Quick default buttons
                HStack {
                    Text("")
                        .frame(width: 100)

                    HStack(spacing: 4) {
                        Button("NULL") {
                            column.defaultValue = "NULL"
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)

                        Button("''") {
                            column.defaultValue = "''"
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)

                        Button("0") {
                            column.defaultValue = "0"
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)

                        if column.dataType.uppercased().contains("TIMESTAMP") ||
                            column.dataType.uppercased().contains("DATETIME") ||
                            column.dataType.uppercased().contains("DATE") {
                            Button("NOW()") {
                                column.defaultValue = databaseType == .postgresql ? "CURRENT_TIMESTAMP" : "NOW()"
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }

                        if column.dataType.uppercased() == "BOOLEAN" ||
                            column.dataType.uppercased() == "BOOL" ||
                            column.dataType.uppercased() == "TINYINT" {
                            Button("TRUE") {
                                column.defaultValue = databaseType == .postgresql ? "TRUE" : "1"
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)

                            Button("FALSE") {
                                column.defaultValue = databaseType == .postgresql ? "FALSE" : "0"
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                    }
                    .font(.caption)
                }

                // Comment
                TextField("Comment", text: Binding(
                    get: { column.comment ?? "" },
                    set: { column.comment = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
            .formStyle(.columns)
        }
    }

    // MARK: - Helpers

    private func isNumericType(_ dataType: String) -> Bool {
        let type = dataType.uppercased()
        let numericTypes = ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT",
                            "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL"]
        return numericTypes.contains { type.contains($0) }
    }
}
