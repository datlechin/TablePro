//
//  SQLReviewPopover.swift
//  TablePro
//
//  Popover view for previewing SQL statements before committing changes.
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

/// Popover view that displays SQL statements with tree-sitter syntax highlighting for review before commit.
struct SQLReviewPopover: View {
    let statements: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var isEditorReady = false
    @State private var editorState = SourceEditorState()

    /// All statements joined for display
    private var combinedSQL: String {
        statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
    }

    /// Calculate popover height based on content lines
    private var contentHeight: CGFloat {
        let lineHeight: CGFloat = 18
        let headerHeight: CGFloat = 30
        let padding: CGFloat = DesignConstants.Spacing.md * 2 + DesignConstants.Spacing.sm
        let editorInsets: CGFloat = 16 // top + bottom content insets

        // Count lines directly from statements to avoid recomputing combinedSQL.
        // Each statement contributes its own line count, plus 2 separator lines (";\n\n")
        // between consecutive statements.
        let lineCount: Int = {
            guard !statements.isEmpty else { return 1 }
            let statementsLineCount = statements.reduce(0) { total, stmt in
                var newlines = 0
                for scalar in stmt.unicodeScalars where scalar == "\n" { newlines += 1 }
                return total + newlines + 1
            }
            // Add separator lines: each separator "\n\n" adds 2 newlines between statements
            let separatorLines = (statements.count - 1) * 2
            return statementsLineCount + separatorLines
        }()
        let editorHeight = CGFloat(lineCount) * lineHeight + editorInsets
        let totalHeight = headerHeight + editorHeight + padding

        return min(max(totalHeight, 120), 500)
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.sm) {
            headerView
            if statements.isEmpty {
                emptyState
            } else {
                editorView
            }
        }
        .padding(DesignConstants.Spacing.md)
        .frame(width: 520, height: contentHeight)
        .onExitCommand {
            dismiss()
        }
        .onAppear {
            // Defer SourceEditor creation to avoid toolbar layout crash
            DispatchQueue.main.async {
                isEditorReady = true
            }
        }
        .onDisappear {
            isEditorReady = false
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text(String(localized: "SQL Preview"))
                .font(.system(size: DesignConstants.FontSize.body, weight: .semibold))
            if !statements.isEmpty {
                Text(
                    "(\(statements.count) \(statements.count == 1 ? String(localized: "statement") : String(localized: "statements")))"
                )
                .font(.system(size: DesignConstants.FontSize.small))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !statements.isEmpty {
                Button(action: copyAllToClipboard) {
                    HStack(spacing: DesignConstants.Spacing.xxs) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? String(localized: "Copied!") : String(localized: "Copy All"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DesignConstants.Spacing.xs) {
            Spacer()
            Image(systemName: "doc.plaintext")
                .font(.system(size: DesignConstants.IconSize.huge))
                .foregroundStyle(.tertiary)
            Text(String(localized: "No pending changes"))
                .font(.system(size: DesignConstants.FontSize.body))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorView: some View {
        if isEditorReady {
            SourceEditor(
                .constant(combinedSQL),
                language: .sql,
                configuration: Self.makeConfiguration(),
                state: $editorState
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        } else {
            // Lightweight placeholder while SourceEditor loads
            Color(nsColor: .textBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Configuration

    private static func makeConfiguration() -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: NSFont.monospacedSystemFont(
                    ofSize: DesignConstants.FontSize.medium, weight: .regular),
                wrapLines: true
            ),
            behavior: .init(
                isEditable: false
            ),
            layout: .init(
                contentInsets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            ),
            peripherals: .init(
                showGutter: false,
                showMinimap: false,
                showFoldingRibbon: false
            )
        )
    }

    // MARK: - Clipboard

    private func copyAllToClipboard() {
        let joined = statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
        ClipboardService.shared.writeText(joined)
        copied = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}
