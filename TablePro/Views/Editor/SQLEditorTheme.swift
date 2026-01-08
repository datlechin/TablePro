//
//  SQLEditorTheme.swift
//  TablePro
//
//  Centralized theme constants for the SQL editor
//

import AppKit

/// Centralized theme configuration for the SQL editor
struct SQLEditorTheme {
    // MARK: - Colors

    /// Background color for the editor
    static let background = NSColor.textBackgroundColor

    /// Default text color
    static let text = NSColor.textColor

    /// Current line highlight color
    static let currentLineHighlight = NSColor.controlAccentColor.withAlphaComponent(0.08)

    /// Bracket matching highlight color
    static let bracketMatchHighlight = NSColor.systemYellow.withAlphaComponent(0.35)

    /// Insertion point (cursor) color
    static let insertionPoint = NSColor.controlAccentColor

    // MARK: - Syntax Highlighting Colors

    /// SQL keywords (SELECT, FROM, WHERE, etc.)
    static let keyword = NSColor.systemBlue

    /// String literals ('...', "...", `...`)
    static let string = NSColor.systemRed

    /// Numeric literals
    static let number = NSColor.systemPurple

    /// Comments (-- and /* */)
    static let comment = NSColor.systemGreen

    /// NULL, TRUE, FALSE
    static let null = NSColor.systemOrange

    // MARK: - Fonts

    /// Main editor font
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Line number font
    static let lineNumberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    // MARK: - Sizes

    /// Text container inset
    static let textContainerInset = NSSize(width: 0, height: 5)

    /// Line fragment padding (left/right margin inside text container)
    static let lineFragmentPadding: CGFloat = 5

    /// Line number ruler thickness (will be calculated based on digits)
    static let lineNumberRulerMinThickness: CGFloat = 40

    /// Corner radius for rounded highlights
    static let highlightCornerRadius: CGFloat = 2

    // MARK: - Line Number Ruler Colors

    /// Line number text color
    static let lineNumberText = NSColor.secondaryLabelColor

    /// Line number ruler background
    static let lineNumberBackground = NSColor.controlBackgroundColor.withAlphaComponent(0.5)

    /// Line number ruler border
    static let lineNumberBorder = NSColor.separatorColor
}
