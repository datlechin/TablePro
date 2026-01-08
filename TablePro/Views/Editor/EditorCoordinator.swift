//
//  EditorCoordinator.swift
//  TablePro
//
//  Coordinator for bridging SwiftUI and AppKit, preventing feedback loops
//

import AppKit
import SwiftUI

/// Coordinator that prevents feedback loops between SwiftUI and NSTextView
@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate {
    // MARK: - Properties

    @Binding var text: String
    @Binding var cursorPosition: Int

    weak var textView: EditorTextView?

    var onExecute: (() -> Void)?

    // Syntax highlighting
    private var syntaxHighlighter: SyntaxHighlighter?

    // Completion
    private var completionEngine: CompletionEngine?
    private let completionWindow = SQLCompletionWindowController()
    private var completionDebounceTask: Task<Void, Never>?
    private var currentCompletionContext: CompletionContext?
    private var suppressNextCompletion: Bool = false

    // Prevent SwiftUI -> NSTextView feedback loop
    private var isUpdatingFromTextView: Bool = false

    // MARK: - Initialization

    init(
        text: Binding<String>,
        cursorPosition: Binding<Int>,
        onExecute: (() -> Void)?,
        schemaProvider: SQLSchemaProvider?
    ) {
        _text = text
        _cursorPosition = cursorPosition
        self.onExecute = onExecute

        super.init()

        // Create completion engine if schema provider is available
        if let provider = schemaProvider {
            self.completionEngine = CompletionEngine(schemaProvider: provider)
        }

        // Set up completion callbacks
        completionWindow.onSelect = { [weak self] item in
            self?.insertCompletion(item)
        }
    }

    // MARK: - Setup

    /// Wire up the text view after creation
    func setup(textView: EditorTextView, textStorage: NSTextStorage) {
        self.textView = textView
        textView.delegate = self

        // Create syntax highlighter
        syntaxHighlighter = SyntaxHighlighter(textStorage: textStorage)

        // Apply initial highlighting
        syntaxHighlighter?.highlightFullDocument()

        // Set up callbacks
        textView.onExecute = { [weak self] in
            self?.onExecute?()
        }

        textView.onManualCompletion = { [weak self] in
            self?.triggerCompletionManually()
        }

        textView.onKeyEvent = { [weak self] event in
            self?.handleKeyEvent(event) ?? false
        }

        textView.onClickOutsideCompletion = { [weak self] in
            self?.dismissCompletion()
        }

        // Observe tab switch to dismiss completion (prevents duplicate windows)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTabSwitch),
            name: NSNotification.Name("QueryTabDidChange"),
            object: nil
        )

        // Observe clearSelection notification to dismiss completion
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClearSelection),
            name: .clearSelection,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleTabSwitch() {
        // Dismiss completion when switching tabs to prevent duplicates
        dismissCompletion()
    }

    @objc private func handleClearSelection() {
        // Dismiss completion window if visible
        dismissCompletion()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }

        // Update SwiftUI bindings
        isUpdatingFromTextView = true
        text = textView.string
        cursorPosition = textView.selectedRange().location
        isUpdatingFromTextView = false

        // Note: Syntax highlighting happens automatically via NSTextStorageDelegate
        // No need to manually trigger it here

        // Trigger autocomplete with debounce
        triggerCompletionDebounced()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }

        // Update cursor position binding
        isUpdatingFromTextView = true
        cursorPosition = textView.selectedRange().location
        isUpdatingFromTextView = false
    }

    // MARK: - SwiftUI -> NSTextView Updates

    /// Update text view from SwiftUI (prevents feedback loop)
    func updateTextViewIfNeeded(with newText: String) {
        guard !isUpdatingFromTextView,
              let textView = textView,
              textView.string != newText else { return }

        // Update without breaking undo stack
        // Since this is coming from SwiftUI (external update), we use direct assignment
        textView.string = newText
        syntaxHighlighter?.highlightFullDocument()
    }

    // MARK: - Completion

    private func triggerCompletionDebounced() {
        // Skip if we just inserted a completion
        if suppressNextCompletion {
            suppressNextCompletion = false
            return
        }

        completionDebounceTask?.cancel()
        completionDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms debounce
            guard !Task.isCancelled else { return }
            await showCompletions()
        }
    }

    func triggerCompletionManually() {
        Task { @MainActor in
            await showCompletions()
        }
    }

    @MainActor
    private func showCompletions() async {
        guard let textView = textView,
              let completionEngine = completionEngine else { return }

        let cursorPosition = textView.selectedRange().location
        let text = textView.string

        // Don't show autocomplete right after semicolon or newline-only context
        if cursorPosition > 0 {
            let prevIndex = text.index(text.startIndex, offsetBy: cursorPosition - 1)
            let prevChar = text[prevIndex]
            if prevChar == ";" || prevChar == "\n" {
                let afterCursor = String(text[text.index(text.startIndex, offsetBy: cursorPosition)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if afterCursor.isEmpty || cursorPosition == text.count {
                    completionWindow.dismiss()
                    return
                }
            }
        }

        // Get completions from engine
        guard let context = await completionEngine.getCompletions(
            text: text,
            cursorPosition: cursorPosition
        ) else {
            completionWindow.dismiss()
            return
        }

        self.currentCompletionContext = context

        // Calculate screen position for completion window
        guard let screenPoint = calculateCompletionWindowPosition() else {
            return
        }

        // Show completion window (window controller handles dismissing old window if needed)
        completionWindow.showCompletions(context.items, at: screenPoint, relativeTo: textView.window)
    }

    private func calculateCompletionWindowPosition() -> NSPoint? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }

        let text = textView.string
        let cursorPosition = textView.selectedRange().location

        guard !text.isEmpty else { return nil }

        // Ensure cursor position is valid
        let safePosition = min(max(0, cursorPosition), text.count)

        // Ensure layout is up to date
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: text.count))

        // Get glyph count safely
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return nil }

        // Safe glyph index calculation
        let charIndex = min(safePosition, text.count - 1)
        let glyphIndex = min(layoutManager.glyphIndexForCharacter(at: max(0, charIndex)), glyphCount - 1)

        // Get line rect safely
        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

        // Get glyph location within line
        if glyphIndex < glyphCount {
            let glyphPoint = layoutManager.location(forGlyphAt: glyphIndex)
            lineRect.origin.x += glyphPoint.x
        }

        let textContainerOrigin = textView.textContainerOrigin
        lineRect.origin.x += textContainerOrigin.x
        lineRect.origin.y += textContainerOrigin.y + lineRect.height

        // Convert to screen coordinates
        let windowPoint = textView.convert(lineRect.origin, to: nil)
        return textView.window?.convertPoint(toScreen: windowPoint)
    }

    private func insertCompletion(_ item: SQLCompletionItem) {
        guard let textView = textView,
              let context = currentCompletionContext else { return }

        let insertText = item.insertText
        let replaceRange = context.replacementRange

        // Suppress next autocomplete trigger to prevent loop
        suppressNextCompletion = true

        // Insert the completion using proper undo-safe API
        if textView.shouldChangeText(in: replaceRange, replacementString: insertText) {
            textView.replaceCharacters(in: replaceRange, with: insertText)
            textView.didChangeText()
        }

        // Dismiss completion window
        completionWindow.dismiss()
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Let completion window handle arrow keys, return, escape
        completionWindow.handleKeyEvent(event)
    }

    /// Dismiss completion window
    func dismissCompletion() {
        completionWindow.dismiss()
    }
}
