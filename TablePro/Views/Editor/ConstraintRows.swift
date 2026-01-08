//
//  ConstraintRows.swift
//  TablePro
//
//  Row views for foreign keys, indexes, and check constraints
//  Updated with modern card styling and better visual hierarchy
//

import SwiftUI

// MARK: - Foreign Key Row

struct ForeignKeyRow: View {
    @Binding var foreignKey: ForeignKeyConstraint
    let availableColumns: [String]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.sm) {
            // Header
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: DesignConstants.FontSize.small))
                        .foregroundStyle(.blue)

                    Text(foreignKey.name.isEmpty ? "(unnamed)" : foreignKey.name)
                        .font(.system(size: DesignConstants.FontSize.body, weight: .medium))
                }

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: DesignConstants.FontSize.caption))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete Foreign Key")
            }

            // Fields
            VStack(spacing: DesignConstants.Spacing.xs) {
                // Name
                TextField("Constraint name", text: $foreignKey.name)
                    .textFieldStyle(.roundedBorder)

                // Table reference
                TextField("Referenced table", text: $foreignKey.referencedTable)
                    .textFieldStyle(.roundedBorder)

                // Columns (simplified - show as comma-separated)
                TextField("Columns (comma-separated)", text: Binding(
                    get: { foreignKey.columns.joined(separator: ", ") },
                    set: { foreignKey.columns = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
                ))
                .textFieldStyle(.roundedBorder)

                TextField("Referenced columns (comma-separated)", text: Binding(
                    get: { foreignKey.referencedColumns.joined(separator: ", ") },
                    set: { foreignKey.referencedColumns = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
        .padding(DesignConstants.Spacing.sm)
        .background(DesignConstants.Colors.cardBackground)
        .cornerRadius(DesignConstants.CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                .stroke(DesignConstants.Colors.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Index Row

struct IndexRow: View {
    @Binding var index: IndexDefinition
    let availableColumns: [String]
    let databaseType: DatabaseType
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.sm) {
            // Header
            HStack {
                HStack(spacing: 4) {
                    // Type badge
                    Text(index.isUnique ? "UNIQUE" : "INDEX")
                        .font(.system(size: DesignConstants.FontSize.tiny, weight: .medium))
                        .foregroundStyle(index.isUnique ? .white : DesignConstants.Colors.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background((index.isUnique ? Color.blue : DesignConstants.Colors.badgeBackground))
                        .cornerRadius(DesignConstants.CornerRadius.small)

                    Text(index.name.isEmpty ? "(unnamed)" : index.name)
                        .font(.system(size: DesignConstants.FontSize.body, weight: .medium))
                }

                Spacer()

                Toggle("Unique", isOn: $index.isUnique)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: DesignConstants.FontSize.caption))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete Index")
            }

            // Fields
            VStack(spacing: DesignConstants.Spacing.xs) {
                TextField("Index name", text: $index.name)
                    .textFieldStyle(.roundedBorder)

                // Columns (simplified - would need multi-select in real impl)
                TextField("Columns (comma-separated)", text: Binding(
                    get: { index.columns.joined(separator: ", ") },
                    set: { index.columns = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
                ))
                .textFieldStyle(.roundedBorder)

                // Note: Index type is enum-based in model, managed via isUnique toggle above
            }
        }
        .padding(DesignConstants.Spacing.sm)
        .background(DesignConstants.Colors.cardBackground)
        .cornerRadius(DesignConstants.CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                .stroke(DesignConstants.Colors.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Check Constraint Row

struct CheckConstraintRow: View {
    @Binding var constraint: CheckConstraint
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.sm) {
            // Header
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: DesignConstants.FontSize.small))
                        .foregroundStyle(.green)

                    Text(constraint.name.isEmpty ? "(unnamed)" : constraint.name)
                        .font(.system(size: DesignConstants.FontSize.body, weight: .medium))
                }

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: DesignConstants.FontSize.caption))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete Check Constraint")
            }

            // Fields
            VStack(spacing: DesignConstants.Spacing.xs) {
                TextField("Constraint name", text: $constraint.name)
                    .textFieldStyle(.roundedBorder)

                TextField("Expression (e.g., age >= 0)", text: $constraint.expression)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding(DesignConstants.Spacing.sm)
        .background(DesignConstants.Colors.cardBackground)
        .cornerRadius(DesignConstants.CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                .stroke(DesignConstants.Colors.border, lineWidth: 0.5)
        )
    }
}
