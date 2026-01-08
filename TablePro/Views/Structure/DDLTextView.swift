//
//  DDLTextView.swift
//  TablePro
//
//  Simple AppKit text view for displaying DDL with syntax highlighting
//

import AppKit
import SwiftUI

/// Simple AppKit-based text view for DDL display - NO LINE NUMBERS FOR NOW
struct DDLTextView: NSViewRepresentable {
    let ddl: String
    @Binding var fontSize: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        // Configure text view - SIMPLE SETUP
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor

        // Disable line wrapping
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true

        // CRITICAL: Set the text
        textView.string = ddl

        // Apply basic syntax highlighting
        if !ddl.isEmpty {
            applyBasicSyntaxHighlighting(to: textView, fontSize: fontSize)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Update font if changed
        if let currentFont = textView.font, currentFont.pointSize != fontSize {
            textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            if !textView.string.isEmpty {
                applyBasicSyntaxHighlighting(to: textView, fontSize: fontSize)
            }
        }

        // Update text if changed
        if textView.string != ddl {
            textView.string = ddl
            if !ddl.isEmpty {
                applyBasicSyntaxHighlighting(to: textView, fontSize: fontSize)
            }
        }
    }

    /// Apply basic SQL syntax highlighting
    private func applyBasicSyntaxHighlighting(to textView: NSTextView, fontSize: CGFloat) {
        guard let textStorage = textView.textStorage else { return }
        guard textStorage.length > 0 else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)

        // Reset to base style
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textStorage.addAttribute(.font, value: font, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        // SQL Keywords (blue)
        let keywords = [
            "CREATE", "TABLE", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
            "NOT", "NULL", "DEFAULT", "UNIQUE", "INDEX", "AUTO_INCREMENT",
            "ON", "DELETE", "UPDATE", "CASCADE", "RESTRICT", "SET",
            "INT", "INTEGER", "VARCHAR", "CHAR", "TEXT", "TIMESTAMP", "DATETIME"
        ]

        for keyword in keywords {
            highlightPattern("\\b\(keyword)\\b", color: .systemBlue, in: textStorage)
        }

        // Strings (red)
        highlightPattern("'[^']*'", color: .systemRed, in: textStorage)

        // Backticks (orange)
        highlightPattern("`[^`]*`", color: .systemOrange, in: textStorage)

        // Numbers (purple)
        highlightPattern("\\b\\d+\\b", color: .systemPurple, in: textStorage)
    }

    private func highlightPattern(_ pattern: String, color: NSColor, in textStorage: NSTextStorage) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }

        let range = NSRange(location: 0, length: textStorage.length)
        let matches = regex.matches(in: textStorage.string, options: [], range: range)

        for match in matches {
            textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
