//
//  SectionHeaderView.swift
//  TablePro
//
//  Reusable section header with collapse/expand, count, and action buttons.
//  Provides consistent styling across the app.
//

import SwiftUI

struct SectionHeaderView<Actions: View>: View {
    let title: String
    let icon: String?
    let count: Int?
    let isCollapsible: Bool
    @Binding var isExpanded: Bool
    let actions: () -> Actions

    init(
        title: String,
        icon: String? = nil,
        count: Int? = nil,
        isCollapsible: Bool = false,
        isExpanded: Binding<Bool> = .constant(true),
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.icon = icon
        self.count = count
        self.isCollapsible = isCollapsible
        self._isExpanded = isExpanded
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.xs) {
            // Collapse/expand chevron (if collapsible)
            if isCollapsible {
                Image(systemName: "chevron.right")
                    .font(.system(size: DesignConstants.FontSize.caption, weight: .semibold))
                    .foregroundStyle(DesignConstants.Colors.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: DesignConstants.AnimationDuration.normal), value: isExpanded)
            }

            // Icon (optional)
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: DesignConstants.FontSize.body))
                    .foregroundStyle(DesignConstants.Colors.secondaryText)
            }

            // Title
            Text(title)
                .font(.system(size: DesignConstants.FontSize.title3, weight: .semibold))
                .foregroundStyle(DesignConstants.Colors.primaryText)

            // Count badge (optional)
            if let count = count {
                Text("(\(count))")
                    .font(.system(size: DesignConstants.FontSize.small))
                    .foregroundStyle(DesignConstants.Colors.tertiaryText)
            }

            Spacer()

            // Action buttons
            actions()
        }
        .padding(.horizontal, DesignConstants.Spacing.sm)
        .padding(.vertical, DesignConstants.Spacing.xs)
        .background(
            isCollapsible ?
                DesignConstants.Colors.sectionBackground.opacity(0.5) :
                Color.clear
        )
        .cornerRadius(DesignConstants.CornerRadius.medium)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsible {
                isExpanded.toggle()
            }
        }
    }
}

// MARK: - Convenience Initializer (No Actions)

extension SectionHeaderView where Actions == EmptyView {
    init(
        title: String,
        icon: String? = nil,
        count: Int? = nil,
        isCollapsible: Bool = false,
        isExpanded: Binding<Bool> = .constant(true)
    ) {
        self.init(
            title: title,
            icon: icon,
            count: count,
            isCollapsible: isCollapsible,
            isExpanded: isExpanded
        )               { EmptyView() }
    }
}
