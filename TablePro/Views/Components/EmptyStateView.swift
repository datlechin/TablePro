//
//  EmptyStateView.swift
//  TablePro
//
//  Reusable empty state component for professional, clean empty states.
//  Used throughout the app when lists or sections have no content.
//

import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let description: String?
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        icon: String,
        title: String,
        description: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.sm) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: DesignConstants.IconSize.huge))
                .foregroundStyle(DesignConstants.Colors.tertiaryText)
                .padding(.bottom, DesignConstants.Spacing.xxs)

            // Title
            Text(title)
                .font(.system(size: DesignConstants.FontSize.body, weight: .medium))
                .foregroundStyle(DesignConstants.Colors.secondaryText)

            // Description (optional)
            if let description = description {
                Text(description)
                    .font(.system(size: DesignConstants.FontSize.small))
                    .foregroundStyle(DesignConstants.Colors.tertiaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action button (optional)
            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: DesignConstants.FontSize.small))
                        Text(actionTitle)
                            .font(.system(size: DesignConstants.FontSize.small))
                    }
                }
                .buttonStyle(.borderless)
                .padding(.top, DesignConstants.Spacing.xxs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Convenience Initializers

extension EmptyStateView {
    /// Empty state for foreign keys
    static func foreignKeys(onAdd: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "link",
            title: "No Foreign Keys Yet",
            description: "Click + to add a relationship between this table and another",
            actionTitle: "Add Foreign Key",
            action: onAdd
        )
    }

    /// Empty state for indexes
    static func indexes(onAdd: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "list.bullet.indent",
            title: "No Indexes Defined",
            description: "Add indexes to improve query performance on frequently searched columns",
            actionTitle: "Add Index",
            action: onAdd
        )
    }

    /// Empty state for check constraints
    static func checkConstraints(onAdd: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "checkmark.shield",
            title: "No Check Constraints",
            description: "Add validation rules to ensure data integrity",
            actionTitle: "Add Check Constraint",
            action: onAdd
        )
    }

    /// Empty state for columns
    static func columns(onAdd: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "tablecells",
            title: "No Columns Defined",
            description: "Every table needs at least one column. Click + to get started",
            actionTitle: "Add Column",
            action: onAdd
        )
    }
}
