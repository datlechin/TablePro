//
//  SQLEditorView.swift
//  TablePro
//
//  Production-quality SQL editor using AppKit NSTextView
//  Fully rewritten with clean architecture
//

import AppKit
import SwiftUI

// MARK: - SQLEditorView

/// SwiftUI wrapper for the SQL editor
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorPosition: Int
    var onExecute: (() -> Void)?
    var schemaProvider: SQLSchemaProvider?

    func makeNSView(context: Context) -> NSView {
        // Create container view to hold line numbers and scroll view
        let containerView = NSView()

        // Create scroll view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = SQLEditorTheme.background

        // Create text storage, layout manager, and text container
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = SQLEditorTheme.lineFragmentPadding
        layoutManager.addTextContainer(textContainer)

        // Create text view using EditorTextView with the text container
        let textView = EditorTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = SQLEditorTheme.font
        textView.textColor = SQLEditorTheme.text
        textView.backgroundColor = SQLEditorTheme.background
        textView.drawsBackground = true
        textView.insertionPointColor = SQLEditorTheme.insertionPoint
        textView.textContainerInset = SQLEditorTheme.textContainerInset

        // Disable automatic text substitutions for SQL syntax integrity
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Set initial text
        textView.string = text

        // Set up coordinator (textStorage is now guaranteed to exist)
        context.coordinator.setup(textView: textView, textStorage: textStorage)

        // MUST set documentView BEFORE creating line number view
        scrollView.documentView = textView

        // Create custom line number view (positioned left of scroll view)
        let lineNumberView = LineNumberView(textView: textView, scrollView: scrollView)

        // Add both views to container
        containerView.addSubview(lineNumberView)
        containerView.addSubview(scrollView)

        // Disable autoresizing masks (use Auto Layout)
        lineNumberView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Set up layout constraints
        NSLayoutConstraint.activate([
            // Line number view: left side, full height, intrinsic width
            lineNumberView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            lineNumberView.topAnchor.constraint(equalTo: containerView.topAnchor),
            lineNumberView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            // Scroll view: right side, full height
            scrollView.leadingAnchor.constraint(equalTo: lineNumberView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Extract scroll view from container view and update text if changed from SwiftUI side
        if let scrollView = nsView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView {
            context.coordinator.updateTextViewIfNeeded(with: text)
        }
    }

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(
            text: $text,
            cursorPosition: $cursorPosition,
            onExecute: onExecute,
            schemaProvider: schemaProvider
        )
    }
}

// MARK: - Preview

#Preview {
    SQLEditorView(
        text: .constant("SELECT * FROM users\nWHERE active = true;"),
        cursorPosition: .constant(0)
    )
    .frame(width: 500, height: 200)
}
