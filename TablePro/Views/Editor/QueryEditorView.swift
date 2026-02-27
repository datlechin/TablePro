//
//  QueryEditorView.swift
//  TablePro
//
//  SQL query editor wrapper with toolbar
//

import CodeEditSourceEditor
import os
import SwiftUI

extension Notification.Name {
    static let formatQueryRequested = Notification.Name("formatQueryRequested")
    static let sendAIPrompt = Notification.Name("sendAIPrompt")
    static let aiFixError = Notification.Name("aiFixError")
    static let aiExplainSelection = Notification.Name("aiExplainSelection")
    static let aiOptimizeSelection = Notification.Name("aiOptimizeSelection")
}

/// SQL query editor view with execute button
struct QueryEditorView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryEditorView")

    @EnvironmentObject private var appState: AppState

    @Binding var queryText: String
    @Binding var cursorPositions: [CursorPosition]
    var onExecute: () -> Void
    var schemaProvider: SQLSchemaProvider?
    var databaseType: DatabaseType?
    var onCloseTab: (() -> Void)?

    @State private var vimMode: VimMode = .normal
    @State private var isVimEnabled = AppSettingsManager.shared.editor.vimModeEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Editor header with toolbar (above editor, higher z-index)
            editorToolbar
                .zIndex(1)

            Divider()

            // SQL Editor (CodeEditSourceEditor-based with tree-sitter highlighting)
            SQLEditorView(
                text: $queryText,
                cursorPositions: $cursorPositions,
                schemaProvider: schemaProvider,
                databaseType: databaseType,
                vimMode: $vimMode,
                onCloseTab: onCloseTab
            )
            .frame(minHeight: 100)
            .clipped()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .formatQueryRequested)) { _ in
            formatQuery()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorSettingsDidChange)) { _ in
            isVimEnabled = AppSettingsManager.shared.editor.vimModeEnabled
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack {
            Text("Query")
                .font(.headline)
                .foregroundStyle(.secondary)

            if isVimEnabled {
                VimModeIndicatorView(mode: vimMode)
            }

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
            .help("Format Query (⌥⌘F)")
            .keyboardShortcut("f", modifiers: [.option, .command])

            Divider()
                .frame(height: 16)

            // Explain button
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
            .disabled(!appState.hasQueryText)

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
        // Get current database type from active session
        let dbType = DatabaseManager.shared.currentSession?.connection.type ?? .mysql

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
