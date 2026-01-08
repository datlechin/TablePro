//
//  CompletionEngine.swift
//  TablePro
//
//  Stateless completion engine - pure logic, no UI
//

import Foundation

/// Completion context returned by the engine
struct CompletionContext {
    let items: [SQLCompletionItem]
    let replacementRange: NSRange
    let sqlContext: SQLContext
}

/// Stateless completion engine that generates suggestions
final class CompletionEngine {
    // MARK: - Properties

    private let provider: SQLCompletionProvider

    // MARK: - Initialization

    init(schemaProvider: SQLSchemaProvider) {
        self.provider = SQLCompletionProvider(schemaProvider: schemaProvider)
    }

    // MARK: - Public API

    /// Get completions for the given text and cursor position
    /// This is a pure function - no side effects
    func getCompletions(
        text: String,
        cursorPosition: Int
    ) async -> CompletionContext? {
        // Get completions from provider
        let (items, context) = await provider.getCompletions(
            text: text,
            cursorPosition: cursorPosition
        )

        // Don't return empty results
        guard !items.isEmpty else {
            return nil
        }

        // Calculate replacement range
        let replaceStart = context.prefixRange.lowerBound
        let replaceEnd = context.prefixRange.upperBound
        let replacementRange = NSRange(location: replaceStart, length: replaceEnd - replaceStart)

        return CompletionContext(
            items: items,
            replacementRange: replacementRange,
            sqlContext: context
        )
    }
}
