//
//  ColumnDetailPanel.swift
//  TablePro
//
//  Side panel for detailed column editing with slide animation.
//  Pushes main content to the left (no overlay).
//

import SwiftUI

struct ColumnDetailPanel: View {
    @Binding var column: ColumnDefinition
    let databaseType: DatabaseType
    let isVisible: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.md) {
                    // Basic properties
                    basicPropertiesSection

                    // Constraints
                    constraintsSection

                    // Default value
                    defaultValueSection

                    // Comment
                    commentSection
                }
                .padding(DesignConstants.Spacing.md)
            }
        }
        .frame(width: 280)
        .background(DesignConstants.Colors.cardBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(DesignConstants.Colors.border)
                .frame(width: 1)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Column Details")
                .font(.system(size: DesignConstants.FontSize.title3, weight: .semibold))

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: DesignConstants.FontSize.small))
                    .foregroundStyle(DesignConstants.Colors.secondaryText)
            }
            .buttonStyle(.borderless)
            .help("Close (ESC)")
        }
        .padding(DesignConstants.Spacing.md)
        .background(DesignConstants.Colors.sectionBackground.opacity(0.3))
    }

    // MARK: - Sections

    private var basicPropertiesSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.sm) {
            SectionLabel("Basic")

            // Column name
            DetailFormField(label: "Name") {
                TextField("Column name", text: $column.name)
                    .textFieldStyle(.roundedBorder)
            }

            // Data type
            DetailFormField(label: "Type") {
                DataTypePicker(
                    selectedType: $column.dataType,
                    databaseType: databaseType
                )
            }

            // Length (if applicable)
            if column.needsLength(for: databaseType) {
                DetailFormField(label: "Length") {
                    TextField("Length", value: $column.length, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }

            // Precision/Scale (for DECIMAL)
            if column.dataType.uppercased().contains("DECIMAL") ||
                column.dataType.uppercased().contains("NUMERIC") {
                HStack(spacing: DesignConstants.Spacing.sm) {
                    DetailFormField(label: "Precision") {
                        TextField("", value: $column.length, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }

                    DetailFormField(label: "Scale") {
                        TextField("", value: $column.precision, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                }
            }
        }
    }

    private var constraintsSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.sm) {
            SectionLabel("Constraints")

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
                Toggle("NOT NULL", isOn: $column.notNull)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                if column.supportsAutoIncrement(for: databaseType) {
                    Toggle("Auto Increment", isOn: $column.autoIncrement)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }

                if (databaseType == .mysql || databaseType == .mariadb) &&
                    isNumericType(column.dataType) {
                    Toggle("Unsigned", isOn: $column.unsigned)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)

                    Toggle("Zero Fill", isOn: $column.zerofill)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
            }
        }
    }

    private var defaultValueSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.sm) {
            SectionLabel("Default Value")

            TextField("Default value", text: Binding(
                get: { column.defaultValue ?? "" },
                set: { column.defaultValue = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)

            // Quick default buttons
            HStack(spacing: 4) {
                QuickDefaultButton("NULL") { column.defaultValue = "NULL" }
                QuickDefaultButton("''") { column.defaultValue = "''" }
                QuickDefaultButton("0") { column.defaultValue = "0" }

                if supportsTimestampDefaults {
                    QuickDefaultButton("NOW()") {
                        column.defaultValue = databaseType == .postgresql ? "CURRENT_TIMESTAMP" : "NOW()"
                    }
                }

                if supportsBooleanDefaults {
                    QuickDefaultButton("TRUE") {
                        column.defaultValue = databaseType == .postgresql ? "TRUE" : "1"
                    }
                    QuickDefaultButton("FALSE") {
                        column.defaultValue = databaseType == .postgresql ? "FALSE" : "0"
                    }
                }
            }
        }
    }

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.sm) {
            SectionLabel("Comment")

            TextField("Optional description", text: Binding(
                get: { column.comment ?? "" },
                set: { column.comment = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Helpers

    private var supportsTimestampDefaults: Bool {
        let type = column.dataType.uppercased()
        return type.contains("TIMESTAMP") || type.contains("DATETIME") || type.contains("DATE")
    }

    private var supportsBooleanDefaults: Bool {
        let type = column.dataType.uppercased()
        return type == "BOOLEAN" || type == "BOOL" || type == "TINYINT"
    }

    private func isNumericType(_ dataType: String) -> Bool {
        let type = dataType.uppercased()
        let numericTypes = ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT",
                            "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL"]
        return numericTypes.contains { type.contains($0) }
    }
}

// MARK: - Helper Views

private struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: DesignConstants.FontSize.small, weight: .semibold))
            .foregroundStyle(DesignConstants.Colors.secondaryText)
            .textCase(.uppercase)
    }
}

private struct DetailFormField<Content: View>: View {
    let label: String
    let content: () -> Content

    init(label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: DesignConstants.FontSize.small))
                .foregroundStyle(DesignConstants.Colors.secondaryText)

            content()
        }
    }
}

private struct QuickDefaultButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: DesignConstants.FontSize.caption))
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
    }
}
