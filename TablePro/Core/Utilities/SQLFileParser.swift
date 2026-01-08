//
//  SQLFileParser.swift
//  TablePro
//
//  Streaming SQL file parser that splits SQL statements while handling
//  comments, string literals, and escape sequences.
//
//  Implementation: Uses a finite state machine to track parser context
//  (normal, in-comment, in-string) while processing files in 4KB chunks.
//  Handles edge cases where multi-character sequences (comments, escapes)
//  span chunk boundaries by deferring processing of special characters
//  until the next chunk arrives.
//

import Foundation

/// SQL statement parser that handles comments, strings, and multi-line statements
final class SQLFileParser {
    // MARK: - Parser State

    private enum ParserState {
        case normal
        case inSingleLineComment
        case inMultiLineComment
        case inSingleQuotedString
        case inDoubleQuotedString
        case inBacktickQuotedString
    }

    // MARK: - Public API

    /// Parse SQL file and return async stream of statements with line numbers
    /// - Parameters:
    ///   - url: File URL to parse
    ///   - encoding: Text encoding to use
    /// - Returns: AsyncStream of (statement, lineNumber) tuples
    func parseFile(
        url: URL,
        encoding: String.Encoding
    ) async throws -> AsyncStream<(statement: String, lineNumber: Int)> {
        AsyncStream { continuation in
            Task {
                do {
                    let fileHandle = try FileHandle(forReadingFrom: url)
                    defer {
                        do {
                            try fileHandle.close()
                        } catch {
                            print("WARNING: Failed to close file handle for \(url.path): \(error)")
                        }
                    }

                    var state: ParserState = .normal
                    var currentStatement = ""
                    var currentLine = 1
                    var statementStartLine = 1
                    var buffer = ""

                    // Read file in chunks
                    let chunkSize = 4_096

                    while true {
                        let data = fileHandle.readData(ofLength: chunkSize)
                        if data.isEmpty { break }

                        guard let chunk = String(data: data, encoding: encoding) else {
                            // Encoding failure - log error and finish stream
                            print("ERROR: Failed to decode file chunk with encoding \(encoding.description)")
                            print("This usually means the file encoding doesn't match the selected encoding option.")
                            continuation.finish()
                            return
                        }

                        buffer += chunk

                        // Process buffer character by character
                        var index = buffer.startIndex

                        while index < buffer.endIndex {
                            let char = buffer[index]
                            let nextIndex = buffer.index(after: index)
                            let nextChar: Character? = nextIndex < buffer.endIndex ? buffer[nextIndex] : nil

                            // At chunk boundary: defer processing of characters that could start
                            // multi-character sequences until we have the next chunk
                            if nextChar == nil && (char == "-" || char == "/" || char == "\\" || char == "*") {
                                // Keep this character in buffer for next chunk
                                break
                            }

                            // Track line numbers
                            if char == "\n" {
                                currentLine += 1
                            }

                            // Track whether we already advanced the index in the state machine logic.
                            // Used for multi-character sequences like --, /*, */ and escape sequences
                            // like \', '', \" where we need to skip both characters at once.
                            var didManuallyAdvance = false

                            // State machine transitions
                            switch state {
                            case .normal:
                                if char == "-" && nextChar == "-" {
                                    // Start of single-line comment (skip both '-' chars)
                                    state = .inSingleLineComment
                                    if nextChar == "\n" { currentLine += 1 }
                                    index = buffer.index(after: nextIndex)
                                    didManuallyAdvance = true
                                } else if char == "/" && nextChar == "*" {
                                    // Start of multi-line comment (skip both '/*' chars)
                                    state = .inMultiLineComment
                                    if nextChar == "\n" { currentLine += 1 }
                                    index = buffer.index(after: nextIndex)
                                    didManuallyAdvance = true
                                } else if char == "'" {
                                    // Start of single-quoted string
                                    state = .inSingleQuotedString
                                    // Track statement start on first non-whitespace character
                                    if currentStatement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        statementStartLine = currentLine
                                    }
                                    currentStatement.append(char)
                                } else if char == "\"" {
                                    // Start of double-quoted string
                                    state = .inDoubleQuotedString
                                    // Track statement start on first non-whitespace character
                                    if currentStatement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        statementStartLine = currentLine
                                    }
                                    currentStatement.append(char)
                                } else if char == "`" {
                                    // Start of backtick-quoted string
                                    state = .inBacktickQuotedString
                                    // Track statement start on first non-whitespace character
                                    if currentStatement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        statementStartLine = currentLine
                                    }
                                    currentStatement.append(char)
                                } else if char == ";" {
                                    // Statement boundary!
                                    let trimmed = currentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        continuation.yield((trimmed, statementStartLine))
                                    }
                                    currentStatement = ""
                                    // Don't update statementStartLine here - will be set when next statement starts
                                } else {
                                    // Track statement start on first non-whitespace character
                                    if currentStatement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !char.isWhitespace {
                                        statementStartLine = currentLine
                                    }
                                    currentStatement.append(char)
                                }

                            case .inSingleLineComment:
                                if char == "\n" {
                                    // End of single-line comment
                                    state = .normal
                                    // Don't append comment to statement
                                }

                            case .inMultiLineComment:
                                if char == "*" && nextChar == "/" {
                                    // End of multi-line comment (skip both '*/' chars)
                                    state = .normal
                                    if nextChar == "\n" { currentLine += 1 }
                                    index = buffer.index(after: nextIndex)
                                    didManuallyAdvance = true
                                }

                            case .inSingleQuotedString:
                                currentStatement.append(char)
                                if char == "\\" && nextChar != nil {
                                    // Backslash escape (MySQL, PostgreSQL): \' escapes the quote
                                    // Append both '\' and the escaped character, then skip both
                                    currentStatement.append(nextChar!)
                                    if nextChar == "\n" { currentLine += 1 }
                                    index = buffer.index(after: nextIndex)
                                    didManuallyAdvance = true
                                } else if char == "'" && nextChar == "'" {
                                    // SQL standard escape: '' (doubled quote) escapes the quote
                                    // Append both quotes, then skip both
                                    currentStatement.append(nextChar!)
                                    if nextChar == "\n" { currentLine += 1 }
                                    index = buffer.index(after: nextIndex)
                                    didManuallyAdvance = true
                                } else if char == "'" {
                                    // End of string
                                    state = .normal
                                }

                            case .inDoubleQuotedString:
                                currentStatement.append(char)
                                if char == "\\" && nextChar != nil {
                                    // Escaped character - append both '\' and next char, then skip both
                                    currentStatement.append(nextChar!)
                                    if nextChar == "\n" { currentLine += 1 }
                                    index = buffer.index(after: nextIndex)
                                    didManuallyAdvance = true
                                } else if char == "\"" {
                                    // End of string
                                    state = .normal
                                }

                            case .inBacktickQuotedString:
                                currentStatement.append(char)
                                if char == "`" {
                                    if let nextChar = nextChar, nextChar == "`" {
                                        // Escaped backtick (``) inside identifier - append both and skip the next one
                                        currentStatement.append(nextChar)
                                        if nextChar == "\n" { currentLine += 1 }
                                        index = buffer.index(after: nextIndex)
                                        didManuallyAdvance = true
                                    } else {
                                        // End of backtick-quoted identifier
                                        state = .normal
                                    }
                                }
                            }

                            // Only advance if we didn't already manually advance
                            if !didManuallyAdvance {
                                index = buffer.index(after: index)
                            }
                        }

                        // Keep any unprocessed characters in buffer for next chunk
                        // (happens when we break early due to potential multi-char sequence at chunk boundary)
                        if index < buffer.endIndex {
                            buffer = String(buffer[index...])
                        } else {
                            buffer = ""
                        }
                    }

                    // Add final statement if any
                    let trimmed = currentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        continuation.yield((trimmed, statementStartLine))
                    }

                    continuation.finish()
                } catch {
                    // Log parsing errors - these should not fail silently
                    print("ERROR: SQL file parsing failed: \(error.localizedDescription)")
                    print("Error details: \(error)")
                    continuation.finish()
                }
            }
        }
    }

    /// Count total statements in file (requires full file scan)
    /// - Parameters:
    ///   - url: File URL to parse
    ///   - encoding: Text encoding to use
    /// - Returns: Total number of statements
    func countStatements(url: URL, encoding: String.Encoding) async throws -> Int {
        var count = 0

        for try await _ in try await parseFile(url: url, encoding: encoding) {
            count += 1
        }

        return count
    }
}
