//
//  TableRowView.swift
//  TablePro
//
//  Row view for a single table in the sidebar.
//

import SwiftUI

/// Row view for a single table
struct TableRow: View {
    let table: TableInfo
    let isActive: Bool
    let isPendingTruncate: Bool
    let isPendingDelete: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Icon with status indicator
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: table.type == .view ? "eye" : "tablecells")
                    .foregroundStyle(iconColor)
                    .frame(width: DesignConstants.IconSize.default)

                // Pending operation indicator
                if isPendingDelete {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: DesignConstants.FontSize.caption))
                        .foregroundStyle(.red)
                        .offset(x: 4, y: 4)
                } else if isPendingTruncate {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: DesignConstants.FontSize.caption))
                        .foregroundStyle(.orange)
                        .offset(x: 4, y: 4)
                }
            }

            Text(table.name)
                .font(.system(size: DesignConstants.FontSize.medium, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(textColor)
        }
        .padding(.vertical, DesignConstants.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tableAccessibilityLabel)
    }

    private var tableAccessibilityLabel: String {
        var label = table.type == .view
            ? String(localized: "View: \(table.name)")
            : String(localized: "Table: \(table.name)")
        if isPendingDelete {
            label += ", " + String(localized: "pending delete")
        } else if isPendingTruncate {
            label += ", " + String(localized: "pending truncate")
        }
        return label
    }

    private var iconColor: Color {
        if isPendingDelete { return .red }
        if isPendingTruncate { return .orange }
        return table.type == .view ? .purple : .blue
    }

    private var textColor: Color {
        if isPendingDelete { return .red }
        if isPendingTruncate { return .orange }
        return .primary
    }
}
