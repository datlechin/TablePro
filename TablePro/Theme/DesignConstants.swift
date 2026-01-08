//
//  DesignConstants.swift
//  TablePro
//
//  Design system constants following macOS Human Interface Guidelines.
//  Use these constants throughout the app for consistent sizing, spacing, and typography.
//

import AppKit
import Foundation
import SwiftUI

/// Design system constants following macOS Human Interface Guidelines
enum DesignConstants {
    // MARK: - Font Sizes

    /// Standard font sizes following macOS typography scale
    enum FontSize {
        /// Tiny text (9pt) - Use for ultra-compact badges, minimal labels (use sparingly)
        static let tiny: CGFloat = 9

        /// Caption text (10pt) - Use for badges, metadata, fine print
        static let caption: CGFloat = 10

        /// Small text (11pt) - Use for secondary labels, helper text
        static let small: CGFloat = 11

        /// Medium text (12pt) - Use for UI controls, toolbar labels (between small and body)
        static let medium: CGFloat = 12

        /// Body text (13pt) - Use for primary content, form fields
        static let body: CGFloat = 13

        /// Title 3 (15pt) - Use for section headers
        static let title3: CGFloat = 15

        /// Title 2 (17pt) - Use for panel titles
        static let title2: CGFloat = 17
    }

    // MARK: - Icon Sizes

    /// Standard icon sizes following macOS design patterns
    enum IconSize {
        /// Tiny indicators (6pt) - Use for minimal status dots (use sparingly)
        static let tinyDot: CGFloat = 6

        /// Status dot (8pt) - Use for connection status indicators
        static let statusDot: CGFloat = 8

        /// Small icons (12pt) - Use for tight UI elements, badges
        static let small: CGFloat = 12

        /// Default icons (14pt) - Use for most UI icons, status indicators
        static let `default`: CGFloat = 14

        /// Medium icons (16pt) - Use for toolbar icons, headers
        static let medium: CGFloat = 16

        /// Large icons (20pt) - Use for prominent UI elements
        static let large: CGFloat = 20

        /// Extra large icons (24pt) - Use for empty states, feature highlights
        static let extraLarge: CGFloat = 24

        /// Huge icons (32pt) - Use for welcome screens, large empty states
        static let huge: CGFloat = 32

        /// Massive icons (64pt) - Use for success/error full-screen states
        static let massive: CGFloat = 64
    }

    // MARK: - Spacing

    /// Standard spacing increments following 4pt grid system
    enum Spacing {
        /// 2pt spacing - Use sparingly for very tight layouts
        static let xxxs: CGFloat = 2

        /// 4pt spacing - Minimum recommended spacing between elements
        static let xxs: CGFloat = 4

        /// 8pt spacing - Standard spacing for related elements
        static let xs: CGFloat = 8

        /// 12pt spacing - Comfortable spacing between groups
        static let sm: CGFloat = 12

        /// 16pt spacing - Spacing for separate sections
        static let md: CGFloat = 16

        /// 20pt spacing - Large spacing for visual separation
        static let lg: CGFloat = 20

        /// 24pt spacing - Extra large spacing for major sections
        static let xl: CGFloat = 24
    }

    // MARK: - Row Heights

    /// Standard row heights for lists and tables
    enum RowHeight {
        /// Compact row height (24pt) - Use for dense data tables, autocomplete
        static let compact: CGFloat = 24

        /// Table row height (32pt) - Use for table editors like column list
        static let table: CGFloat = 32

        /// Comfortable row height (44pt) - Use for touch-friendly lists, multi-line content
        static let comfortable: CGFloat = 44
    }

    // MARK: - Insets

    /// Standard list row insets following macOS patterns (AppKit)
    static let listRowInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    /// SwiftUI EdgeInsets version for list rows
    /// Note: SwiftUI EdgeInsets uses top/leading/bottom/trailing
    static let swiftUIListRowInsets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

    // MARK: - Colors

    /// Semantic colors for UI elements
    enum Colors {
        // Backgrounds
        static let sectionBackground = Color(nsColor: .controlBackgroundColor)
        static let cardBackground = Color(nsColor: .windowBackgroundColor)
        static let alternateRow = Color(nsColor: .controlBackgroundColor).opacity(0.5)
        static let hoverBackground = Color.accentColor.opacity(0.05)
        static let selectedBackground = Color.accentColor.opacity(0.1)

        // Borders
        static let border = Color(nsColor: .separatorColor)
        static let selectedBorder = Color.accentColor

        // Text
        static let primaryText = Color.primary
        static let secondaryText = Color.secondary
        static let tertiaryText = Color.secondary.opacity(0.6)

        // Semantic
        static let success = Color.green
        static let warning = Color.orange
        static let error = Color.red
        static let info = Color.blue

        // Badges
        static let badgeBackground = Color.secondary.opacity(0.15)
        static let primaryKeyBadge = Color.blue.opacity(0.15)
        static let autoIncrementBadge = Color.purple.opacity(0.15)
        static let nullBadge = Color.secondary.opacity(0.1)
    }

    // MARK: - Corner Radius

    /// Standard corner radius values
    enum CornerRadius {
        /// Small radius (4pt) - Use for badges, pills
        static let small: CGFloat = 4

        /// Medium radius (6pt) - Use for cards, sections
        static let medium: CGFloat = 6

        /// Large radius (8pt) - Use for panels, modals
        static let large: CGFloat = 8
    }

    // MARK: - Animation Duration

    /// Standard animation durations
    enum AnimationDuration {
        /// Fast animation (100ms) - Use for hover states
        static let fast: Double = 0.1

        /// Normal animation (150ms) - Use for button presses
        static let normal: Double = 0.15

        /// Smooth animation (200ms) - Use for panel slides
        static let smooth: Double = 0.2

        /// Slow animation (300ms) - Use for section expand/collapse
        static let slow: Double = 0.3
    }

    // MARK: - Shadow

    /// Standard shadow styles
    enum Shadow {
        /// Card shadow (subtle elevation)
        static let card: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
            (Color.black.opacity(0.1), 4, 0, 2)

        /// Panel shadow (stronger elevation)
        static let panel: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
            (Color.black.opacity(0.15), 8, -2, 0)
    }

    // MARK: - Column Widths (for table editors)

    /// Standard column widths for table-style layouts
    enum ColumnWidth {
        /// Drag handle column (24pt)
        static let dragHandle: CGFloat = 24

        /// Actions column (80pt)
        static let actions: CGFloat = 80

        /// Name column (minimum 140pt, flexible)
        static let nameMin: CGFloat = 140

        /// Type column (minimum 120pt, flexible)
        static let typeMin: CGFloat = 120

        /// Attributes column (minimum 100pt, flexible)
        static let attributesMin: CGFloat = 100

        /// Default column (minimum 100pt, flexible)
        static let defaultMin: CGFloat = 100
    }
}
