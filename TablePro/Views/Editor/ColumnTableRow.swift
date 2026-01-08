//
//  ColumnTableRow.swift
//  TablePro
//
//  Single row in the column table editor with hover states, inline editing,
//  and professional TablePlus-style UI.
//

import SwiftUI
import UniformTypeIdentifiers

struct ColumnTableRow: View {
    @Binding var column: ColumnDefinition
    let isPrimaryKey: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onEdit: () -> Void

    @State private var isHovered = false
    @State private var editingCell: EditingCell?

    enum EditingCell {
        case name
        case defaultValue
    }

    var body: some View {
        HStack(spacing: 0) {
            // Drag handle (visible on hover)
            dragHandleCell

            // Name cell
            nameCell

            // Type cell
            typeCell

            // Attributes cell
            attributesCell

            // Default cell
            defaultCell

            // Actions cell (visible on hover/selected)
            actionsCell
        }
        .frame(height: DesignConstants.RowHeight.table)
        .frame(maxWidth: .infinity)
        .background(rowBackground)
        .overlay(selectedBorderOverlay, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onEdit()
            }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                onSelect()
            }
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Cells

    private var dragHandleCell: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10))
            .foregroundStyle(DesignConstants.Colors.tertiaryText)
            .frame(width: DesignConstants.ColumnWidth.dragHandle)
            .opacity(isHovered ? 0.6 : 0)
    }

    private var nameCell: some View {
        HStack(spacing: 4) {
            // Primary key icon
            if isPrimaryKey {
                Image(systemName: "key.fill")
                    .font(.system(size: DesignConstants.FontSize.caption))
                    .foregroundStyle(.blue)
            }

            // Name text or text field
            if editingCell == .name {
                TextField("Column name", text: $column.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: DesignConstants.FontSize.body))
                    .onSubmit {
                        editingCell = nil
                    }
            } else {
                Text(column.name.isEmpty ? "(unnamed)" : column.name)
                    .font(.system(size: DesignConstants.FontSize.body))
                    .foregroundStyle(column.name.isEmpty ? DesignConstants.Colors.tertiaryText : DesignConstants.Colors.primaryText)
                    .onTapGesture(count: 2) {
                        editingCell = .name
                    }
            }
        }
        .frame(minWidth: DesignConstants.ColumnWidth.nameMin, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignConstants.Spacing.xs)
    }

    private var typeCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(column.dataType)
                .font(.system(size: DesignConstants.FontSize.body, design: .monospaced))
                .foregroundStyle(DesignConstants.Colors.secondaryText)

            // Length/precision info
            if let length = column.length, length > 0 {
                Text("(\(length)\(column.precision != nil && column.precision! > 0 ? ", \(column.precision!)" : ""))")
                    .font(.system(size: DesignConstants.FontSize.caption, design: .monospaced))
                    .foregroundStyle(DesignConstants.Colors.tertiaryText)
            }
        }
        .frame(minWidth: DesignConstants.ColumnWidth.typeMin, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignConstants.Spacing.xs)
    }

    private var attributesCell: some View {
        HStack(spacing: 4) {
            // Auto-increment badge
            if column.autoIncrement {
                AttributeBadge(text: "AUTO", color: .purple)
            }

            // NULL badge
            if !column.notNull {
                AttributeBadge(text: "NULL", color: .secondary)
            }

            // Unsigned badge (MySQL only)
            if column.unsigned {
                AttributeBadge(text: "UNSIGNED", color: .orange)
            }
        }
        .frame(minWidth: DesignConstants.ColumnWidth.attributesMin, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignConstants.Spacing.xs)
    }

    private var defaultCell: some View {
        Group {
            if editingCell == .defaultValue {
                TextField("Default", text: Binding(
                    get: { column.defaultValue ?? "" },
                    set: { column.defaultValue = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: DesignConstants.FontSize.small, design: .monospaced))
                .onSubmit {
                    editingCell = nil
                }
            } else {
                Text(column.defaultValue ?? "—")
                    .font(.system(size: DesignConstants.FontSize.small, design: .monospaced))
                    .foregroundStyle(column.defaultValue == nil ? DesignConstants.Colors.tertiaryText : DesignConstants.Colors.secondaryText)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        editingCell = .defaultValue
                    }
            }
        }
        .frame(minWidth: DesignConstants.ColumnWidth.defaultMin, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignConstants.Spacing.xs)
    }

    private var actionsCell: some View {
        HStack(spacing: 2) {
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: DesignConstants.FontSize.caption))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.borderless)
            .help("Edit Details (Double-click)")

            Button(action: onMoveUp) {
                Image(systemName: "chevron.up")
                    .font(.system(size: DesignConstants.FontSize.caption))
                    .foregroundStyle(DesignConstants.Colors.secondaryText)
            }
            .buttonStyle(.borderless)
            .help("Move Up (⌘↑)")

            Button(action: onMoveDown) {
                Image(systemName: "chevron.down")
                    .font(.system(size: DesignConstants.FontSize.caption))
                    .foregroundStyle(DesignConstants.Colors.secondaryText)
            }
            .buttonStyle(.borderless)
            .help("Move Down (⌘↓)")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: DesignConstants.FontSize.caption))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete (⌫)")
        }
        .frame(width: DesignConstants.ColumnWidth.actions)
        .opacity(isHovered || isSelected ? 1 : 0)
    }

    // MARK: - Styling

    private var rowBackground: some View {
        Group {
            if isSelected {
                DesignConstants.Colors.selectedBackground
            } else if isHovered {
                DesignConstants.Colors.hoverBackground
            } else {
                Color.clear
            }
        }
    }

    private var selectedBorderOverlay: some View {
        Group {
            if isSelected {
                Rectangle()
                    .fill(DesignConstants.Colors.selectedBorder)
                    .frame(width: 3)
            }
        }
    }
}

// MARK: - Attribute Badge

private struct AttributeBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: DesignConstants.FontSize.tiny, weight: .medium))
            .foregroundStyle(color == .secondary ? DesignConstants.Colors.secondaryText : color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background((color == .secondary ? DesignConstants.Colors.nullBadge : color.opacity(0.15)))
            .cornerRadius(DesignConstants.CornerRadius.small)
    }
}
