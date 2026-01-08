//
//  SyntaxHighlighter.swift
//  TablePro
//
//  Incremental syntax highlighter for SQL using NSTextStorageDelegate
//

import AppKit

/// Incremental syntax highlighter that operates on edited ranges only
final class SyntaxHighlighter: NSObject, NSTextStorageDelegate {
    // MARK: - Properties

    private weak var textStorage: NSTextStorage?

    /// SQL keywords for highlighting (synced with SQLKeywords for consistency)
    private static let keywords: Set<String> = [
        // DQL
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN",
        "AS", "DISTINCT", "ALL", "TOP",

        // Joins
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "ON", "USING",

        // Ordering & Grouping
        "ORDER", "BY", "ASC", "DESC", "NULLS", "FIRST", "LAST",
        "GROUP", "HAVING",

        // Limiting
        "LIMIT", "OFFSET", "FETCH", "NEXT", "ROWS", "ONLY",

        // Set operations
        "UNION", "INTERSECT", "EXCEPT", "MINUS",

        // Subqueries
        "EXISTS", "ANY", "SOME",

        // DML
        "INSERT", "INTO", "VALUES", "DEFAULT",
        "UPDATE", "SET",
        "DELETE", "TRUNCATE",

        // DDL - Tables
        "CREATE", "ALTER", "DROP", "RENAME", "MODIFY", "CHANGE",
        "TABLE", "VIEW", "INDEX", "DATABASE", "SCHEMA",
        "ADD", "COLUMN", "AFTER", "BEFORE",

        // Constraints
        "CONSTRAINT", "PRIMARY", "FOREIGN", "KEY", "REFERENCES",
        "UNIQUE", "CHECK", "CASCADE", "RESTRICT", "NO", "ACTION",
        "AUTO_INCREMENT", "AUTOINCREMENT", "SERIAL",

        // Data types
        "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT",
        "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",
        "VARCHAR", "CHAR", "TEXT", "BLOB", "CLOB",
        "DATE", "TIME", "DATETIME", "TIMESTAMP", "YEAR",
        "BOOLEAN", "BOOL", "BIT", "JSON", "JSONB", "XML",
        "UUID", "BINARY", "VARBINARY", "UNSIGNED", "SIGNED",

        // Conditionals
        "CASE", "WHEN", "THEN", "ELSE", "END", "IF",

        // NULL/Boolean
        "NULL", "IS", "TRUE", "FALSE", "UNKNOWN",

        // Transactions
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "TRANSACTION",

        // Other
        "WITH", "RECURSIVE", "TEMPORARY", "TEMP",
        "EXPLAIN", "ANALYZE", "DESCRIBE", "SHOW",
        "WINDOW", "OVER", "PARTITION", "RANGE",
        "ILIKE", "SIMILAR", "REGEXP", "RLIKE"
    ]

    // MARK: - Compiled Regex Patterns (Thread-Safe, Compiled Once)

    private static let keywordRegex: NSRegularExpression? = {
        let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let stringRegexes: [NSRegularExpression] = {
        ["'[^']*'", "\"[^\"]*\"", "`[^`]*`"].compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static let numberRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
    }()

    private static let singleLineCommentRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "--[^\\n]*")
    }()

    private static let multiLineCommentRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/")
    }()

    private static let nullBoolRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b(NULL|TRUE|FALSE)\\b", options: .caseInsensitive)
    }()

    // MARK: - Initialization

    init(textStorage: NSTextStorage) {
        self.textStorage = textStorage
        super.init()
        textStorage.delegate = self
    }

    // MARK: - NSTextStorageDelegate

    /// Called after text storage processes an edit
    /// This is THE RIGHT PLACE to apply syntax highlighting
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Only process character changes, not attribute-only changes
        guard editedMask.contains(.editedCharacters) else { return }

        // Expand range to full line(s)
        let text = textStorage.string
        guard !text.isEmpty else { return }

        let expandedRange = expandToLineRange(editedRange, in: text)

        // Apply highlighting to the expanded range only
        highlightRange(expandedRange, in: textStorage)
    }

    // MARK: - Public API

    /// Manually trigger full document highlighting (e.g., on initial load)
    func highlightFullDocument() {
        guard let textStorage = textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }
        highlightRange(fullRange, in: textStorage)
    }

    // MARK: - Private Helpers

    /// Expand edited range to include full lines
    private func expandToLineRange(_ range: NSRange, in text: String) -> NSRange {
        guard !text.isEmpty, range.location < text.count else {
            return NSRange(location: 0, length: text.count)
        }

        let nsString = text as NSString
        let lineRange = nsString.lineRange(for: range)
        return lineRange
    }

    /// Apply syntax highlighting to a specific range
    private func highlightRange(_ range: NSRange, in textStorage: NSTextStorage) {
        guard range.length > 0, range.location + range.length <= textStorage.length else {
            return
        }

        let text = textStorage.string
        let nsText = text as NSString
        let substring = nsText.substring(with: range)

        // Begin editing (batch attribute changes)
        textStorage.beginEditing()

        // Reset to default attributes in this range
        textStorage.addAttributes([
            .font: SQLEditorTheme.font,
            .foregroundColor: SQLEditorTheme.text
        ], range: range)

        // Detect strings and comments first (these take precedence)
        var stringRanges: [NSRange] = []
        var commentRanges: [NSRange] = []

        // Find all strings
        for regex in Self.stringRegexes {
            regex.enumerateMatches(in: substring, range: NSRange(location: 0, length: substring.count)) { match, _, _ in
                if let matchRange = match?.range {
                    let absoluteRange = NSRange(location: range.location + matchRange.location, length: matchRange.length)
                    stringRanges.append(absoluteRange)
                    textStorage.addAttribute(.foregroundColor, value: SQLEditorTheme.string, range: absoluteRange)
                }
            }
        }

        // Find all comments
        Self.singleLineCommentRegex?.enumerateMatches(in: substring, range: NSRange(location: 0, length: substring.count)) { match, _, _ in
            if let matchRange = match?.range {
                let absoluteRange = NSRange(location: range.location + matchRange.location, length: matchRange.length)
                commentRanges.append(absoluteRange)
                textStorage.addAttribute(.foregroundColor, value: SQLEditorTheme.comment, range: absoluteRange)
            }
        }

        Self.multiLineCommentRegex?.enumerateMatches(in: substring, range: NSRange(location: 0, length: substring.count)) { match, _, _ in
            if let matchRange = match?.range {
                let absoluteRange = NSRange(location: range.location + matchRange.location, length: matchRange.length)
                commentRanges.append(absoluteRange)
                textStorage.addAttribute(.foregroundColor, value: SQLEditorTheme.comment, range: absoluteRange)
            }
        }

        // Helper to check if a range overlaps with strings or comments
        let isInsideStringOrComment: (NSRange) -> Bool = { checkRange in
            for stringRange in stringRanges {
                if NSIntersectionRange(checkRange, stringRange).length > 0 {
                    return true
                }
            }
            for commentRange in commentRanges {
                if NSIntersectionRange(checkRange, commentRange).length > 0 {
                    return true
                }
            }
            return false
        }

        // Highlight keywords (only outside strings/comments)
        Self.keywordRegex?.enumerateMatches(in: substring, range: NSRange(location: 0, length: substring.count)) { match, _, _ in
            if let matchRange = match?.range {
                let absoluteRange = NSRange(location: range.location + matchRange.location, length: matchRange.length)
                if !isInsideStringOrComment(absoluteRange) {
                    textStorage.addAttribute(.foregroundColor, value: SQLEditorTheme.keyword, range: absoluteRange)
                }
            }
        }

        // Highlight numbers (only outside strings/comments)
        Self.numberRegex?.enumerateMatches(in: substring, range: NSRange(location: 0, length: substring.count)) { match, _, _ in
            if let matchRange = match?.range {
                let absoluteRange = NSRange(location: range.location + matchRange.location, length: matchRange.length)
                if !isInsideStringOrComment(absoluteRange) {
                    textStorage.addAttribute(.foregroundColor, value: SQLEditorTheme.number, range: absoluteRange)
                }
            }
        }

        // Highlight NULL, TRUE, FALSE (only outside strings/comments)
        Self.nullBoolRegex?.enumerateMatches(in: substring, range: NSRange(location: 0, length: substring.count)) { match, _, _ in
            if let matchRange = match?.range {
                let absoluteRange = NSRange(location: range.location + matchRange.location, length: matchRange.length)
                if !isInsideStringOrComment(absoluteRange) {
                    textStorage.addAttribute(.foregroundColor, value: SQLEditorTheme.null, range: absoluteRange)
                }
            }
        }

        // End editing (commit changes)
        textStorage.endEditing()
    }
}
