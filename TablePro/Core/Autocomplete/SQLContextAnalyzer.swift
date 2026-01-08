//
//  SQLContextAnalyzer.swift
//  TablePro
//
//  Analyzes SQL query text to determine cursor context for autocomplete
//

import Foundation

/// Type of SQL clause the cursor is in
enum SQLClauseType {
    case select         // In SELECT list
    case from           // After FROM
    case join           // After JOIN
    case on             // After ON (join condition)
    case where_         // After WHERE
    case and            // After AND/OR
    case groupBy        // After GROUP BY
    case orderBy        // After ORDER BY
    case having         // After HAVING
    case set            // After SET (UPDATE)
    case into           // After INTO (INSERT)
    case values         // After VALUES
    case insertColumns  // Column list in INSERT
    case functionArg    // Inside function parentheses
    case caseExpression // Inside CASE WHEN expression
    case inList         // Inside IN (...) list
    case limit          // After LIMIT/OFFSET
    case alterTable       // After ALTER TABLE tablename
    case alterTableColumn // After DROP/MODIFY/CHANGE/RENAME COLUMN - need column names
    case createTable      // Inside CREATE TABLE definition
    case columnDef        // Typing column data type (after column name)
    case unknown          // Unknown or start of query
}

/// Represents a table reference with optional alias
struct TableReference: Equatable, Sendable {
    let tableName: String
    let alias: String?

    /// Returns the identifier that should be used to reference this table
    var identifier: String {
        alias ?? tableName
    }
}

/// Result of context analysis
struct SQLContext {
    let clauseType: SQLClauseType
    let prefix: String              // Current word being typed
    let prefixRange: Range<Int>     // Range of prefix in original text
    let dotPrefix: String?          // Table/alias before dot (e.g., "u" in "u.name")
    let tableReferences: [TableReference]  // All tables in scope
    let isInsideString: Bool        // Inside a string literal
    let isInsideComment: Bool       // Inside a comment

    // Enhanced context for smarter completions
    let cteNames: [String]          // Common Table Expression names in scope
    let nestingLevel: Int           // Subquery nesting level (0 = main query)
    let currentFunction: String?    // If inside function args, the function name
    let isAfterComma: Bool          // True if immediately after a comma

    init(
        clauseType: SQLClauseType,
        prefix: String,
        prefixRange: Range<Int>,
        dotPrefix: String?,
        tableReferences: [TableReference],
        isInsideString: Bool,
        isInsideComment: Bool,
        cteNames: [String] = [],
        nestingLevel: Int = 0,
        currentFunction: String? = nil,
        isAfterComma: Bool = false
    ) {
        self.clauseType = clauseType
        self.prefix = prefix
        self.prefixRange = prefixRange
        self.dotPrefix = dotPrefix
        self.tableReferences = tableReferences
        self.isInsideString = isInsideString
        self.isInsideComment = isInsideComment
        self.cteNames = cteNames
        self.nestingLevel = nestingLevel
        self.currentFunction = currentFunction
        self.isAfterComma = isAfterComma
    }
}

/// Analyzes SQL query to determine completion context
final class SQLContextAnalyzer {
    // MARK: - Cached Regex Patterns (Compiled Once at Class Load)

    /// Pre-compiled clause detection patterns for performance
    /// ORDER MATTERS: More specific patterns must come before general ones
    private static let clauseRegexes: [(regex: NSRegularExpression, clause: SQLClauseType)] = {
        let patterns: [(String, SQLClauseType)] = [
            // DDL patterns (most specific first)
            ("\\b(?:ADD|MODIFY|CHANGE)\\s+(?:COLUMN\\s+)?\\w+\\s+\\w*$", .columnDef),
            ("\\bALTER\\s+TABLE\\s+[`\"']?\\w+[`\"']?\\s+(?:DROP|MODIFY|CHANGE|RENAME)\\s+(?:COLUMN\\s+)?(?:[`\"']?\\w+[`\"']?)?\\s*$", .alterTableColumn),
            ("\\bALTER\\s+TABLE\\s+[^;]*\\bAFTER\\s+\\w*$", .alterTableColumn),
            ("\\bALTER\\s+TABLE\\s+[`\"']?\\w+[`\"']?\\s+\\w*$", .alterTable),
            ("\\bCREATE\\s+TABLE\\s+[^(]*\\([^)]*$", .createTable),
            // Enhanced context patterns
            ("\\bIN\\s*\\([^)]*$", .inList),
            ("\\bCASE\\s+(?:WHEN\\s+[^;]*)?$", .caseExpression),
            ("\\b(LIMIT|OFFSET)\\s+\\d*$", .limit),
            // Standard clause patterns
            ("\\bVALUES\\s*\\([^)]*$", .values),
            ("\\bINSERT\\s+INTO\\s+\\w+\\s*\\([^)]*$", .insertColumns),
            ("\\bINTO\\s+\\w*$", .into),
            ("\\bSET\\s+[^;]*$", .set),
            ("\\bHAVING\\s+[^;]*$", .having),
            ("\\bORDER\\s+BY\\s+[^;]*$", .orderBy),
            ("\\bGROUP\\s+BY\\s+[^;]*$", .groupBy),
            ("\\b(AND|OR)\\s+\\w*$", .and),
            ("\\bWHERE\\s+[^;]*$", .where_),
            ("\\bON\\s+[^;]*$", .on),
            // JOIN patterns
            ("(?:LEFT|RIGHT|INNER|OUTER|FULL|CROSS)?\\s*(?:OUTER)?\\s*JOIN\\s+[`\"']?\\w+[`\"']?(?:\\s+(?:AS\\s+)?\\w+)?\\s*$", .join),
            ("\\bJOIN\\s+[`\"']?\\w*[`\"']?\\s*$", .join),
            // FROM patterns
            ("\\bFROM\\s+[`\"']?\\w+[`\"']?(?:\\s+(?:AS\\s+)?\\w+)?\\s*$", .from),
            ("\\bFROM\\s+\\w*$", .from),
            // SELECT is most general
            ("\\bSELECT\\s+[^;]*$", .select),
        ]
        return patterns.compactMap { pattern, clause in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                assertionFailure("Invalid SQL clause regex pattern: \(pattern)")
                return nil
            }
            return (regex, clause)
        }
    }()

    /// Pre-compiled regex for removing strings and comments (force-unwrap safe: simple patterns)
    private static let singleQuoteStringRegex: NSRegularExpression = {
        if let regex = try? NSRegularExpression(pattern: "'[^']*'") {
            return regex
        }
        assertionFailure("Failed to compile singleQuoteStringRegex - invalid pattern")
        // Fallback to a regex that matches nothing
        return try! NSRegularExpression(pattern: "(?!)")
    }()

    private static let doubleQuoteStringRegex: NSRegularExpression = {
        if let regex = try? NSRegularExpression(pattern: "\"[^\"]*\"") {
            return regex
        }
        assertionFailure("Failed to compile doubleQuoteStringRegex - invalid pattern")
        // Fallback to a regex that matches nothing
        return try! NSRegularExpression(pattern: "(?!)")
    }()

    private static let blockCommentRegex: NSRegularExpression = {
        if let regex = try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/") {
            return regex
        }
        assertionFailure("Failed to compile blockCommentRegex - invalid pattern")
        // Fallback to a regex that matches nothing
        return try! NSRegularExpression(pattern: "(?!)")
    }()

    private static let lineCommentRegex: NSRegularExpression = {
        if let regex = try? NSRegularExpression(pattern: "--[^\n]*") {
            return regex
        }
        assertionFailure("Failed to compile lineCommentRegex - invalid pattern")
        // Fallback to a regex that matches nothing
        return try! NSRegularExpression(pattern: "(?!)")
    }()

    // MARK: - Main Analysis

    /// Analyze the query at the given cursor position
    func analyze(query: String, cursorPosition: Int) -> SQLContext {
        let safePosition = min(cursorPosition, query.count)

        // Extract the current statement for multi-statement queries
        let (currentStatement, statementOffset) = extractCurrentStatement(from: query, cursorPosition: safePosition)
        let adjustedPosition = safePosition - statementOffset

        let textBeforeCursor = String(currentStatement.prefix(max(0, adjustedPosition)))

        // Check if inside string or comment
        if isInsideString(textBeforeCursor) {
            return SQLContext(
                clauseType: .unknown,
                prefix: "",
                prefixRange: safePosition..<safePosition,
                dotPrefix: nil,
                tableReferences: [],
                isInsideString: true,
                isInsideComment: false
            )
        }

        if isInsideComment(textBeforeCursor) {
            return SQLContext(
                clauseType: .unknown,
                prefix: "",
                prefixRange: safePosition..<safePosition,
                dotPrefix: nil,
                tableReferences: [],
                isInsideString: false,
                isInsideComment: true
            )
        }

        // Extract prefix and dot prefix
        let (prefix, prefixStart, dotPrefix) = extractPrefix(from: textBeforeCursor)

        // Find all table references in the current statement
        var tableReferences = extractTableReferences(from: currentStatement)

        // Extract CTEs from the current statement
        let cteNames = extractCTENames(from: currentStatement)

        // Add CTE names as table references
        for cteName in cteNames {
            let cteRef = TableReference(tableName: cteName, alias: nil)
            if !tableReferences.contains(cteRef) {
                tableReferences.append(cteRef)
            }
        }

        // Extract ALTER TABLE table name and add to references
        if let alterTableName = extractAlterTableName(from: currentStatement) {
            let alterRef = TableReference(tableName: alterTableName, alias: nil)
            if !tableReferences.contains(alterRef) {
                tableReferences.append(alterRef)
            }
        }

        // Calculate nesting level (subquery depth)
        let nestingLevel = calculateNestingLevel(in: textBeforeCursor)

        // Detect function context
        let currentFunction = detectFunctionContext(in: textBeforeCursor)

        // Check if immediately after comma
        let isAfterComma = checkIfAfterComma(textBeforeCursor)

        // Determine clause type
        let clauseType = determineClauseType(textBeforeCursor: textBeforeCursor, dotPrefix: dotPrefix, currentFunction: currentFunction)

        return SQLContext(
            clauseType: clauseType,
            prefix: prefix,
            prefixRange: (statementOffset + prefixStart)..<safePosition,
            dotPrefix: dotPrefix,
            tableReferences: tableReferences,
            isInsideString: false,
            isInsideComment: false,
            cteNames: cteNames,
            nestingLevel: nestingLevel,
            currentFunction: currentFunction,
            isAfterComma: isAfterComma
        )
    }

    // MARK: - Multi-Statement Support

    /// Extract the current SQL statement containing the cursor
    private func extractCurrentStatement(from query: String, cursorPosition: Int) -> (statement: String, offset: Int) {
        // Find statement boundaries (semicolons not inside strings/comments)
        var statements: [(range: Range<Int>, text: String)] = []
        var currentStart = 0
        var inString = false
        var inComment = false
        var prevChar: Character = "\0"

        for (index, char) in query.enumerated() {
            // Track string state
            if char == "'" && prevChar != "\\" && !inComment {
                inString.toggle()
            }

            // Track comment state (simple line comment detection)
            if char == "-" && prevChar == "-" && !inString {
                inComment = true
            }
            if char == "\n" && inComment {
                inComment = false
            }

            // Found statement boundary
            if char == ";" && !inString && !inComment {
                let startIndex = query.index(query.startIndex, offsetBy: currentStart)
                let endIndex = query.index(query.startIndex, offsetBy: index + 1)
                let statementText = String(query[startIndex..<endIndex])
                statements.append((range: currentStart..<(index + 1), text: statementText))
                currentStart = index + 1
            }

            prevChar = char
        }

        // Add the last statement (may not end with ;)
        if currentStart < query.count {
            let startIndex = query.index(query.startIndex, offsetBy: currentStart)
            let statementText = String(query[startIndex...])
            statements.append((range: currentStart..<query.count, text: statementText))
        }

        // Find which statement contains the cursor
        for stmt in statements {
            if stmt.range.contains(cursorPosition) ||
                (cursorPosition == stmt.range.upperBound && stmt.range.upperBound == query.count) {
                return (stmt.text, stmt.range.lowerBound)
            }
        }

        // Fallback: return entire query
        return (query, 0)
    }

    // MARK: - CTE Support

    /// Extract CTE (Common Table Expression) names from the query
    private func extractCTENames(from query: String) -> [String] {
        var cteNames: [String] = []

        // Pattern: WITH name AS (...), name2 AS (...)
        // Handle both simple and recursive CTEs
        let pattern = "(?i)\\bWITH\\s+(?:RECURSIVE\\s+)?([\\w]+)\\s+AS\\s*\\("
        let commaPattern = "(?i),\\s*([\\w]+)\\s+AS\\s*\\("

        // Find first CTE
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(query.startIndex..., in: query)
            if let match = regex.firstMatch(in: query, range: range),
               let nameRange = Range(match.range(at: 1), in: query) {
                cteNames.append(String(query[nameRange]))
            }
        }

        // Find additional CTEs (comma-separated)
        if let regex = try? NSRegularExpression(pattern: commaPattern) {
            let range = NSRange(query.startIndex..., in: query)
            regex.enumerateMatches(in: query, range: range) { match, _, _ in
                if let match = match,
                   let nameRange = Range(match.range(at: 1), in: query) {
                    cteNames.append(String(query[nameRange]))
                }
            }
        }

        return cteNames
    }

    // MARK: - Subquery Support

    /// Calculate the nesting level (subquery depth) at cursor position
    private func calculateNestingLevel(in textBeforeCursor: String) -> Int {
        var level = 0
        var inString = false
        var prevChar: Character = "\0"

        for char in textBeforeCursor {
            if char == "'" && prevChar != "\\" {
                inString.toggle()
            }

            if !inString {
                if char == "(" {
                    level += 1
                } else if char == ")" {
                    level = max(0, level - 1)
                }
            }

            prevChar = char
        }

        return level
    }

    // MARK: - Function Context

    /// Detect if cursor is inside a function call and return the function name
    private func detectFunctionContext(in textBeforeCursor: String) -> String? {
        var parenStack: [(position: Int, precedingWord: String?)] = []
        var inString = false
        var prevChar: Character = "\0"
        var currentWord = ""
        var lastWord: String?

        for (index, char) in textBeforeCursor.enumerated() {
            if char == "'" && prevChar != "\\" {
                inString.toggle()
            }

            if !inString {
                if char.isLetter || char.isNumber || char == "_" {
                    currentWord.append(char)
                } else {
                    if !currentWord.isEmpty {
                        lastWord = currentWord
                        currentWord = ""
                    }

                    if char == "(" {
                        parenStack.append((position: index, precedingWord: lastWord))
                        lastWord = nil
                    } else if char == ")" {
                        if !parenStack.isEmpty {
                            parenStack.removeLast()
                        }
                    }
                }
            }

            prevChar = char
        }

        // If we're inside parentheses, check if it's a function call
        if let lastParen = parenStack.last,
           let funcName = lastParen.precedingWord {
            // Check if it looks like a function (not a subquery)
            let upperFunc = funcName.uppercased()
            let sqlFunctions = ["COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "IFNULL",
                                "CONCAT", "SUBSTRING", "UPPER", "LOWER", "NOW", "DATE",
                                "CAST", "CONVERT", "ROUND", "ABS", "LENGTH", "TRIM",
                                "GROUP_CONCAT", "DATE_FORMAT", "YEAR", "MONTH", "DAY"]

            // Either known function or doesn't look like SELECT/subquery keywords
            if sqlFunctions.contains(upperFunc) ||
                (!["SELECT", "FROM", "WHERE", "IN", "EXISTS", "NOT"].contains(upperFunc)) {
                return funcName
            }
        }

        return nil
    }

    // MARK: - Comma Detection

    /// Check if the cursor is immediately after a comma (for multi-column contexts)
    private func checkIfAfterComma(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(",")
    }

    // MARK: - Helper Methods

    /// Check if cursor is inside a string literal
    private func isInsideString(_ text: String) -> Bool {
        var inSingleQuote = false
        var inDoubleQuote = false
        var prevChar: Character = "\0"

        for char in text {
            if char == "'" && prevChar != "\\" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == "\"" && prevChar != "\\" && !inSingleQuote {
                inDoubleQuote.toggle()
            }
            prevChar = char
        }

        return inSingleQuote || inDoubleQuote
    }

    /// Check if cursor is inside a comment
    private func isInsideComment(_ text: String) -> Bool {
        // Check for line comment
        if let lastNewline = text.lastIndex(of: "\n") {
            let lineStart = text.index(after: lastNewline)
            let currentLine = String(text[lineStart...])
            if currentLine.contains("--") {
                let dashIndex = currentLine.range(of: "--")!.lowerBound
                // Check if -- is before current position in line
                if currentLine[..<dashIndex].trimmingCharacters(in: .whitespaces).isEmpty ||
                    !currentLine[..<dashIndex].contains("'") {
                    return true
                }
            }
        } else if text.contains("--") {
            // First line and contains --
            if let range = text.range(of: "--") {
                let before = text[..<range.lowerBound]
                // Not inside a string before --
                if !isInsideString(String(before)) {
                    return true
                }
            }
        }

        // Check for block comment
        let openCount = text.components(separatedBy: "/*").count - 1
        let closeCount = text.components(separatedBy: "*/").count - 1
        return openCount > closeCount
    }

    /// Extract the current word prefix and any dot prefix (table.column)
    private func extractPrefix(from text: String) -> (prefix: String, start: Int, dotPrefix: String?) {
        guard !text.isEmpty else {
            return ("", 0, nil)
        }

        // Find start of current identifier
        var prefixStart = text.count
        var foundDot = false
        var dotPosition = -1

        // Scan backwards to find start of identifier
        let chars = Array(text)
        for i in stride(from: chars.count - 1, through: 0, by: -1) {
            let char = chars[i]

            if char == "." && !foundDot {
                foundDot = true
                dotPosition = i
                continue
            }

            if char.isLetter || char.isNumber || char == "_" || char == "`" {
                prefixStart = i
            } else if foundDot && (char.isLetter || char.isNumber || char == "_" || char == "`") {
                prefixStart = i
            } else {
                break
            }
        }

        let prefix: String
        let dotPrefix: String?

        if foundDot && dotPosition > prefixStart {
            // Has dot prefix like "users.na" or "u.na"
            let beforeDot = String(text[text.index(text.startIndex, offsetBy: prefixStart)..<text.index(text.startIndex, offsetBy: dotPosition)])
            let afterDot = String(text[text.index(text.startIndex, offsetBy: dotPosition + 1)...])

            dotPrefix = beforeDot.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            prefix = afterDot
            return (prefix, dotPosition + 1, dotPrefix)
        } else {
            // No dot, just a regular prefix
            prefix = String(text[text.index(text.startIndex, offsetBy: prefixStart)...])
            dotPrefix = nil
            return (prefix, prefixStart, nil)
        }
    }

    /// Extract all table references (table names and aliases) from the query
    private func extractTableReferences(from query: String) -> [TableReference] {
        var references: [TableReference] = []

        // SQL keywords that should NOT be treated as table names
        let sqlKeywords: Set<String> = [
            "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL",
            "JOIN", "ON", "AND", "OR", "WHERE", "SELECT", "FROM", "AS"
        ]

        // Pattern for FROM/JOIN table references with optional alias
        // Updated to handle: LEFT JOIN table, INNER JOIN table, etc.
        let patterns = [
            // FROM table [AS] alias
            "(?i)\\bFROM\\s+[`\"']?([\\w]+)[`\"']?(?:\\s+(?:AS\\s+)?[`\"']?([\\w]+)[`\"']?)?",
            // All types of JOINs: (LEFT|RIGHT|INNER|OUTER|CROSS|FULL)? (OUTER)? JOIN table [AS] alias
            "(?i)(?:LEFT|RIGHT|INNER|OUTER|CROSS|FULL)?\\s*(?:OUTER)?\\s*JOIN\\s+[`\"']?([\\w]+)[`\"']?(?:\\s+(?:AS\\s+)?[`\"']?([\\w]+)[`\"']?)?",
            // UPDATE table [AS] alias
            "(?i)\\bUPDATE\\s+[`\"']?([\\w]+)[`\"']?(?:\\s+(?:AS\\s+)?[`\"']?([\\w]+)[`\"']?)?"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let range = NSRange(query.startIndex..., in: query)
            regex.enumerateMatches(in: query, range: range) { match, _, _ in
                guard let match = match else { return }

                // Group 1: table name
                if let tableRange = Range(match.range(at: 1), in: query) {
                    let tableName = String(query[tableRange])

                    // Skip SQL keywords
                    guard !sqlKeywords.contains(tableName.uppercased()) else { return }

                    // Group 2: alias (optional)
                    var alias: String?
                    if match.numberOfRanges > 2, let aliasRange = Range(match.range(at: 2), in: query) {
                        let aliasCandidate = String(query[aliasRange])
                        // Skip SQL keywords as aliases
                        if !sqlKeywords.contains(aliasCandidate.uppercased()) {
                            alias = aliasCandidate
                        }
                    }

                    // Don't add duplicates
                    let ref = TableReference(tableName: tableName, alias: alias)
                    if !references.contains(ref) {
                        references.append(ref)
                    }
                }
            }
        }

        return references
    }

    /// Pre-compiled regex for extracting table name from ALTER TABLE statements
    private static let alterTableRegex: NSRegularExpression? = {
        // Pattern: ALTER TABLE tablename (supports optional quoting and special characters)
        let pattern = "(?i)\\bALTER\\s+TABLE\\s+[`\"']?([^`\"']+)[`\"']?"
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// Extract table name from ALTER TABLE statement
    private func extractAlterTableName(from query: String) -> String? {
        guard let regex = Self.alterTableRegex else { return nil }

        let range = NSRange(query.startIndex..., in: query)
        if let match = regex.firstMatch(in: query, range: range),
           let tableRange = Range(match.range(at: 1), in: query) {
            return String(query[tableRange])
        }

        return nil
    }

    /// Determine the clause type based on text before cursor
    private func determineClauseType(textBeforeCursor: String, dotPrefix: String?, currentFunction: String? = nil) -> SQLClauseType {
        // If we have a dot prefix, we're looking for columns
        if dotPrefix != nil {
            return .select // Column context
        }

        // If inside a function, return function arg context
        if currentFunction != nil {
            return .functionArg
        }

        let upper = textBeforeCursor.uppercased()

        // Remove string literals and comments for analysis
        let cleaned = removeStringsAndComments(from: upper)

        // Use pre-compiled regex patterns for performance
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        for (regex, clause) in Self.clauseRegexes {
            if regex.firstMatch(in: cleaned, range: range) != nil {
                return clause
            }
        }

        return .unknown
    }

    /// Remove string literals and comments for cleaner analysis
    private func removeStringsAndComments(from text: String) -> String {
        var result = text

        // Use pre-compiled regex patterns for performance
        result = Self.singleQuoteStringRegex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "''"
        )

        result = Self.doubleQuoteStringRegex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "\"\""
        )

        result = Self.blockCommentRegex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )

        result = Self.lineCommentRegex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )

        return result
    }
}
