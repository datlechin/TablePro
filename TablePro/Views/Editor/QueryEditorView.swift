//
//  QueryEditorView.swift
//  TablePro
//
//  SQL query editor wrapper with toolbar
//

import SwiftUI

/// SQL query editor view with execute button
struct QueryEditorView: View {
    @Binding var queryText: String
    @Binding var cursorPosition: Int  // Track cursor for query-at-cursor execution
    var onExecute: () -> Void
    var schemaProvider: SQLSchemaProvider?  // Optional for autocomplete

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Editor header with toolbar (above editor, higher z-index)
            editorToolbar
                .zIndex(1)

            Divider()

            // SQL Editor (AppKit-based with syntax highlighting and built-in line numbers)
            SQLEditorView(text: $queryText, cursorPosition: $cursorPosition, onExecute: onExecute, schemaProvider: schemaProvider)
                .frame(minHeight: 100)
                .clipped()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack {
            Text("Query")
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer()

            // Clear button
            Button(action: { queryText = "" }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear Query (⌘+Delete)")
            .keyboardShortcut(.delete, modifiers: .command)

            // Format button
            Button(action: formatQuery) {
                Image(systemName: "text.alignleft")
            }
            .buttonStyle(.borderless)
            .help("Format Query")

            Divider()
                .frame(height: 16)

            // Execute button
            Button(action: onExecute) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text("Execute")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers

    private func formatQuery() {
        // Basic formatting: uppercase keywords
        let keywords = ["SELECT", "FROM", "WHERE", "ORDER BY", "GROUP BY", "HAVING",
                        "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER",
                        "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON",
                        "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS",
                        "LIMIT", "OFFSET", "DISTINCT", "COUNT", "SUM", "AVG", "MAX", "MIN",
                        "NULL", "IS", "ASC", "DESC", "SET", "VALUES", "INTO", "TABLE"]

        var formatted = queryText
        for keyword in keywords {
            // Match word boundaries
            let pattern = "\\b\(keyword.lowercased())\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(formatted.startIndex..., in: formatted)
                formatted = regex.stringByReplacingMatches(in: formatted, range: range, withTemplate: keyword)
            }
        }
        queryText = formatted
    }
}

#Preview {
    QueryEditorView(
        queryText: .constant("SELECT * FROM users\nWHERE active = true\nORDER BY created_at DESC;"),
        cursorPosition: .constant(0)
    )        {}
    .frame(width: 600, height: 200)
}
