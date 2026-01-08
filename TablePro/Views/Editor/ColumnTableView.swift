//
//  ColumnTableView.swift
//  TablePro
//
//  Table-style column editor with sticky headers, inline editing,
//  and TablePlus-inspired professional UI.
//

import SwiftUI
import UniformTypeIdentifiers

struct ColumnTableView: View {
    @Binding var columns: [ColumnDefinition]
    @Binding var primaryKeyColumns: [String]
    @Binding var selectedColumnId: UUID?
    let databaseType: DatabaseType
    let onDelete: (ColumnDefinition) -> Void
    let onMoveUp: (ColumnDefinition) -> Void
    let onMoveDown: (ColumnDefinition) -> Void
    let onEdit: (ColumnDefinition) -> Void

    @State private var draggedColumn: ColumnDefinition?

    var body: some View {
        VStack(spacing: 0) {
            // Header row (sticky)
            headerRow

            Divider()

            // Column rows
            if columns.isEmpty {
                EmptyStateView.columns {
                    addColumn()
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                            ColumnTableRow(
                                column: Binding(
                                    get: { column },
                                    set: { newValue in
                                        if let idx = columns.firstIndex(where: { $0.id == column.id }) {
                                            columns[idx] = newValue
                                        }
                                    }
                                ),
                                isPrimaryKey: primaryKeyColumns.contains(column.name),
                                isSelected: selectedColumnId == column.id,
                                onSelect: {
                                    selectedColumnId = column.id
                                },
                                onDelete: {
                                    onDelete(column)
                                },
                                onMoveUp: {
                                    onMoveUp(column)
                                },
                                onMoveDown: {
                                    onMoveDown(column)
                                },
                                onEdit: {
                                    onEdit(column)
                                }
                            )
                            .onDrag {
                                draggedColumn = column
                                return NSItemProvider(object: column.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: ColumnTableDropDelegate(
                                column: column,
                                columns: $columns,
                                draggedColumn: $draggedColumn
                            ))

                            if index < columns.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .background(DesignConstants.Colors.cardBackground)
        .cornerRadius(DesignConstants.CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                .stroke(DesignConstants.Colors.border, lineWidth: 0.5)
        )
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 0) {
            // Drag handle column (fixed)
            HeaderCell(title: "", width: DesignConstants.ColumnWidth.dragHandle, isFixed: true)

            // Name column (flexible)
            HeaderCell(title: "Name", width: DesignConstants.ColumnWidth.nameMin, isFixed: false)

            // Type column (flexible)
            HeaderCell(title: "Type", width: DesignConstants.ColumnWidth.typeMin, isFixed: false)

            // Attributes column (flexible)
            HeaderCell(title: "Attributes", width: DesignConstants.ColumnWidth.attributesMin, isFixed: false)

            // Default column (flexible)
            HeaderCell(title: "Default", width: DesignConstants.ColumnWidth.defaultMin, isFixed: false)

            // Actions column (fixed)
            HeaderCell(title: "", width: DesignConstants.ColumnWidth.actions, isFixed: true)
        }
        .frame(height: DesignConstants.RowHeight.table)
        .frame(maxWidth: .infinity)
        .background(DesignConstants.Colors.sectionBackground.opacity(0.5))
    }

    // MARK: - Actions

    private func addColumn() {
        let newColumn = ColumnDefinition(
            name: "column_\(columns.count + 1)",
            dataType: "VARCHAR",
            length: 255
        )
        columns.append(newColumn)
        selectedColumnId = newColumn.id
    }
}

// MARK: - Header Cell

private struct HeaderCell: View {
    let title: String
    let width: CGFloat
    let isFixed: Bool

    var body: some View {
        Group {
            if isFixed {
                Text(title)
                    .font(.system(size: DesignConstants.FontSize.small, weight: .semibold))
                    .foregroundStyle(DesignConstants.Colors.secondaryText)
                    .frame(width: width, alignment: .leading)
                    .padding(.horizontal, DesignConstants.Spacing.xs)
            } else {
                Text(title)
                    .font(.system(size: DesignConstants.FontSize.small, weight: .semibold))
                    .foregroundStyle(DesignConstants.Colors.secondaryText)
                    .frame(minWidth: width, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignConstants.Spacing.xs)
            }
        }
    }
}

// MARK: - Drop Delegate

struct ColumnTableDropDelegate: DropDelegate {
    let column: ColumnDefinition
    @Binding var columns: [ColumnDefinition]
    @Binding var draggedColumn: ColumnDefinition?

    func performDrop(info: DropInfo) -> Bool {
        draggedColumn = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedColumn = draggedColumn,
              draggedColumn.id != column.id,
              let fromIndex = columns.firstIndex(where: { $0.id == draggedColumn.id }),
              let toIndex = columns.firstIndex(where: { $0.id == column.id }) else {
            return
        }

        withAnimation(.easeInOut(duration: DesignConstants.AnimationDuration.normal)) {
            columns.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }
}
