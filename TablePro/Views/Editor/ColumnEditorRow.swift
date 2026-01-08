//
//  ColumnEditorRow.swift
//  TablePro
//
//  Compact row view for a column in the columns list.
//  Shows key properties: name, type, length, nullable, default.
//

import SwiftUI

struct ColumnEditorRow: View {
    let column: ColumnDefinition
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.xs) {
            // Column name
            Text(column.name.isEmpty ? "(unnamed)" : column.name)
                .font(.system(size: DesignConstants.FontSize.body, weight: isSelected ? .medium : .regular))
                .foregroundStyle(column.name.isEmpty ? .secondary : .primary)
                .frame(width: 120, alignment: .leading)

            // Data type with length
            Text(column.fullDataType)
                .font(.system(size: DesignConstants.FontSize.small, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            // Nullable indicator
            if !column.notNull {
                Text("NULL")
                    .font(.system(size: DesignConstants.FontSize.caption))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(3)
            }

            // Auto-increment indicator
            if column.autoIncrement {
                Text("AUTO")
                    .font(.system(size: DesignConstants.FontSize.caption))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(3)
            }

            // Default value
            if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
                HStack(spacing: 2) {
                    Text("=")
                        .foregroundStyle(.secondary)
                    Text(defaultValue)
                        .font(.system(size: DesignConstants.FontSize.small, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 100, alignment: .leading)
            }

            Spacer()

            // Action buttons (show on hover or when selected)
            HStack(spacing: 2) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Move Up")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Move Down")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete Column")
            }
            .opacity(isSelected ? 1 : 0.5)
        }
        .padding(.horizontal, DesignConstants.Spacing.xs)
        .padding(.vertical, DesignConstants.Spacing.xxs)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}
