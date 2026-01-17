//
//  ToolbarDesignTokens.swift
//  TablePro
//
//  Component-specific design tokens for toolbar display.
//  Builds on DesignConstants.swift by referencing base values and adding toolbar-specific semantics.
//
//  ARCHITECTURE: DesignConstants (base) → ToolbarDesignTokens (component-specific)
//

import AppKit
import Foundation
import SwiftUI

/// Component-specific design tokens for toolbar components
/// References DesignConstants for shared values, defines only toolbar-specific semantics
enum ToolbarDesignTokens {
    
    // MARK: - Typography Hierarchy (Xcode-inspired)
    
    enum Typography {
        /// Database type label (11pt, regular, monospaced) - subtle
        static let databaseType = Font.system(
            size: DesignConstants.FontSize.small,
            weight: .regular,
            design: .monospaced
        )
        
        /// Database name (12pt, medium) - clean and readable
        static let databaseName = Font.system(
            size: DesignConstants.FontSize.medium,
            weight: .medium
        )
        
        /// Execution time (11pt, regular, monospaced)
        static let executionTime = Font.system(
            size: DesignConstants.FontSize.small,
            weight: .regular,
            design: .monospaced
        )
        
        /// Tag label (11pt, medium) - clean like Xcode breadcrumbs
        static let tagLabel = Font.system(
            size: DesignConstants.FontSize.small,
            weight: .medium
        )
    }
    
    // MARK: - Tag Styling
    
    enum Tag {
        /// Tag capsule background opacity
        static let backgroundOpacity: CGFloat = 0.2
        
        /// Tag horizontal padding (8pt)
        static let horizontalPadding = DesignConstants.Spacing.xs
        
        /// Tag vertical padding (4pt)
        static let verticalPadding = DesignConstants.Spacing.xxs
    }
    
    // MARK: - Spacing (Balanced for readability)
    
    enum Spacing {
        /// Spacing between icon and text within a component (5pt)
        static let iconTextSpacing: CGFloat = 5
        
        /// Spacing between sections - balanced readability (10pt)
        static let betweenSections: CGFloat = 10
        
        /// Divider height - minimal like Xcode
        static let dividerHeight = DesignConstants.Spacing.sm
        
        /// Icon size (default database/cylinder icon)
        static let iconSize: CGFloat = 13
        
        /// Tag padding from toolbar edge
        static let tagPadding = DesignConstants.Spacing.xs
    }
    
    // MARK: - Animations
    
    enum Animation {
        /// Hover transition duration - references base constant
        static let hover = DesignConstants.AnimationDuration.normal
        
        /// Spring response for bouncy animations
        static let springResponse: Double = 0.4
        
        /// Spring damping fraction
        static let springDamping: Double = 0.7
    }
    
    // MARK: - Colors (Xcode-inspired minimal)
    
    enum Colors {
        /// Divider color - very subtle like Xcode
        static let divider = DesignConstants.Colors.secondaryText.opacity(0.15)
        
        /// Secondary text color - references base constant
        static let secondaryText = DesignConstants.Colors.secondaryText
        
        /// Tertiary text color - slightly more transparent
        static let tertiaryText = DesignConstants.Colors.tertiaryText.opacity(1.05)
    }
}
