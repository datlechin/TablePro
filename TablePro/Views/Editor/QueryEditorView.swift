//
//  QueryEditorView.swift
//  TablePro
//
//  SQL query editor wrapper with toolbar
//

import CodeEditSourceEditor
import os
import SwiftUI

/// SQL query editor view with execute button
struct QueryEditorView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryEditorView")

    @Environment(AppState.self) private var appState

    @Binding var queryText: String
    @Binding var cursorPositions: [CursorPosition]
    var onExecute: () -> Void
    var schemaProvider: SQLSchemaProvider?
    var databaseType: DatabaseType?
    var onCloseTab: (() -> Void)?
    var onExecuteQuery: (() -> Void)?

    @State private var vimMode: VimMode = .normal

    var body: some View {
        let hasQuery = appState.hasQueryText

        VStack(alignment: .leading, spacing: 0) {
            // Editor header with toolbar (above editor, higher z-index)
            editorToolbar(hasQueryText: hasQuery)
                .zIndex(1)

            Divider()

            // SQL Editor (CodeEditSourceEditor-based with tree-sitter highlighting)
            SQLEditorView(
                text: $queryText,
                cursorPositions: $cursorPositions,
                schemaProvider: schemaProvider,
                databaseType: databaseType,
                vimMode: $vimMode,
                onCloseTab: onCloseTab,
                onExecuteQuery: onExecuteQuery
            )
            .frame(minHeight: 100)
            .clipped()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Toolbar

    private func editorToolbar(hasQueryText: Bool) -> some View {
        HStack {
            Text("Query")
                .font(.headline)
                .foregroundStyle(.secondary)

            if AppSettingsManager.shared.editor.vimModeEnabled {
                VimModeIndicatorView(mode: vimMode)
            }

            Spacer()

            // Clear button
            Button(action: { queryText = "" }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear Query")

            // Format button
            Button(action: formatQuery) {
                Image(systemName: "text.alignleft")
            }
            .buttonStyle(.borderless)
            .help("Format Query (⌥⌘F)")
            .keyboardShortcut("f", modifiers: [.option, .command])

            Divider()
                .frame(height: 16)

            if databaseType == .clickhouse {
                Menu {
                    ForEach(ClickHouseExplainVariant.allCases) { variant in
                        Button(variant.rawValue) {
                            NotificationCenter.default.post(
                                name: .explainQuery,
                                object: nil,
                                userInfo: ["variant": variant.rawValue]
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.doc.horizontal")
                        Text("Explain")
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!hasQueryText)
            } else {
                Button {
                    NotificationCenter.default.post(name: .explainQuery, object: nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.doc.horizontal")
                        Text("Explain")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasQueryText)
            }

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
        // Get current database type
        let dbType = databaseType ?? .mysql

        // Create formatter service
        let formatter = SQLFormatterService()
        let options = SQLFormatterOptions.default

        let cursorOffset = cursorPositions.first?.range.location ?? 0

        do {
            // Format SQL with cursor preservation
            let result = try formatter.format(
                queryText,
                dialect: dbType,
                cursorOffset: cursorOffset,
                options: options
            )

            // Update text and cursor position
            queryText = result.formattedSQL
            if let newCursor = result.cursorOffset {
                cursorPositions = [CursorPosition(range: NSRange(location: newCursor, length: 0))]
            }
        } catch {
            Self.logger.error("SQL Formatting error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#Preview {
    QueryEditorView(
        queryText: .constant("SELECT * FROM users\nWHERE active = true\nORDER BY created_at DESC;"),
        cursorPositions: .constant([]),
        onExecute: {},
        databaseType: .mysql
    )
    .frame(width: 600, height: 200)
}
