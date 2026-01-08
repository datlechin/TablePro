//
//  TemplateSheets.swift
//  TablePro
//
//  Sheets for saving and loading table templates
//

import SwiftUI

// MARK: - Save Template Sheet

struct SaveTemplateSheet: View {
    @Binding var templateName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.md) {
            Text("Save Table Template")
                .font(.headline)

            TextField("Template Name", text: $templateName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)

                Spacer()

                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(templateName.isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .padding(DesignConstants.Spacing.md)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 350)
    }
}

// MARK: - Load Template Sheet

struct LoadTemplateSheet: View {
    let templates: [String]
    let onLoad: (String) -> Void
    let onDelete: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedTemplate: String?

    private var listHeight: CGFloat {
        // Dynamic height based on number of templates (max 8 items visible)
        let itemHeight: CGFloat = 30
        let maxItems = min(templates.count, 8)
        return CGFloat(maxItems) * itemHeight + 10
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.md) {
            Text("Load Table Template")
                .font(.headline)

            if templates.isEmpty {
                Text("No saved templates")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 30)
            } else {
                List(templates, id: \.self, selection: $selectedTemplate) { template in
                    HStack {
                        Text(template)
                            .font(.system(size: DesignConstants.FontSize.body))

                        Spacer()

                        Button(action: {
                            onDelete(template)
                        }) {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                                .font(.system(size: DesignConstants.FontSize.small))
                        }
                        .buttonStyle(.borderless)
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(height: listHeight)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)

                Spacer()

                Button("Load") {
                    if let selected = selectedTemplate {
                        onLoad(selected)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTemplate == nil)
                .keyboardShortcut(.return)
            }
        }
        .padding(DesignConstants.Spacing.md)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 400)
    }
}

// MARK: - Import DDL Sheet

struct ImportDDLSheet: View {
    @Binding var ddlText: String
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.md) {
            Text("Import from DDL")
                .font(.headline)

            Text("Paste your CREATE TABLE statement below:")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $ddlText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 250)
                .scrollContentBackground(.hidden)
                .padding(DesignConstants.Spacing.xs)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)

                Spacer()

                Button("Import") {
                    onImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(ddlText.isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(DesignConstants.Spacing.md)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 500)
    }
}

// MARK: - Duplicate Table Sheet

struct DuplicateTableSheet: View {
    let tables: [String]
    @Binding var selectedTable: String?
    let onDuplicate: () -> Void
    let onCancel: () -> Void

    private var listHeight: CGFloat {
        // Dynamic height based on number of tables (max 10 items visible)
        let itemHeight: CGFloat = 30
        let maxItems = min(tables.count, 10)
        return CGFloat(max(maxItems, 1)) * itemHeight + 10
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.md) {
            Text("Duplicate Table Structure")
                .font(.headline)

            Text("Select a table to copy its structure:")
                .font(.caption)
                .foregroundStyle(.secondary)

            if tables.isEmpty {
                ProgressView("Loading tables...")
                    .padding(.vertical, 40)
            } else {
                List(tables, id: \.self, selection: $selectedTable) { table in
                    Text(table)
                        .font(.system(size: DesignConstants.FontSize.body))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(height: listHeight)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)

                Spacer()

                Button("Duplicate") {
                    onDuplicate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTable == nil)
                .keyboardShortcut(.return)
            }
        }
        .padding(DesignConstants.Spacing.md)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 400)
    }
}
