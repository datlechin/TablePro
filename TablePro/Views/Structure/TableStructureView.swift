//
//  TableStructureView.swift
//  TablePro
//
//  View for displaying table structure: columns, indexes, foreign keys
//

import SwiftUI
import UniformTypeIdentifiers

/// Tab selection for structure view
enum StructureTab: String, CaseIterable {
    case columns = "Columns"
    case indexes = "Indexes"
    case foreignKeys = "Foreign Keys"
    case ddl = "DDL"
}

/// View displaying table structure like TablePlus
struct TableStructureView: View {
    let tableName: String
    let connection: DatabaseConnection

    @State private var selectedTab: StructureTab = .columns
    @State private var columns: [ColumnInfo] = []
    @State private var indexes: [IndexInfo] = []
    @State private var foreignKeys: [ForeignKeyInfo] = []
    @State private var ddlStatement: String = ""
    @State private var ddlFontSize: CGFloat = 13
    @State private var showCopyConfirmation = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    // Lazy loading state - track which tabs have been loaded
    @State private var loadedTabs: Set<StructureTab> = []

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(StructureTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Content
            if isLoading {
                ProgressView("Loading structure...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch selectedTab {
                case .columns:
                    columnsTable
                case .indexes:
                    indexesTable
                case .foreignKeys:
                    foreignKeysTable
                case .ddl:
                    ddlView
                }
            }
        }
        .task {
            await loadColumns()  // Always load columns first (default tab)
        }
        .onChange(of: selectedTab) { _, newTab in
            // Lazy load data for newly selected tab
            Task {
                await loadTabDataIfNeeded(newTab)
            }
        }
    }

    // MARK: - Columns Tab

    private var columnsTable: some View {
        Table(columns) {
            TableColumn("Name") { column in
                HStack(spacing: 4) {
                    if column.isPrimaryKey {
                        Image(systemName: "key.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                    Text(column.name)
                        .fontWeight(column.isPrimaryKey ? .semibold : .regular)
                }
            }
            .width(min: 120, ideal: 150)

            TableColumn("Type") { column in
                Text(column.dataType)
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 100, ideal: 120)

            TableColumn("Charset") { column in
                Text(column.charset ?? "-")
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 70, ideal: 90)

            TableColumn("Collation") { column in
                Text(column.collation ?? "-")
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 120, ideal: 160)

            TableColumn("Nullable") { column in
                Image(systemName: column.isNullable ? "checkmark.circle" : "xmark.circle")
                    .foregroundColor(column.isNullable ? .green : .red)
            }
            .width(70)

            TableColumn("Default") { column in
                Text(column.defaultValue ?? "-")
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 80, ideal: 120)

            TableColumn("Extra") { column in
                Text(column.extra ?? "-")
                    .foregroundColor(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Comment") { column in
                Text(column.comment ?? "-")
                    .foregroundColor(.secondary)
                    .font(.body)
                    .lineLimit(2)
            }
            .width(min: 100, ideal: 200)
        }
    }

    // MARK: - Indexes Tab

    private var indexesTable: some View {
        Group {
            if indexes.isEmpty {
                emptyState("No indexes found")
            } else {
                Table(indexes) {
                    TableColumn("Name") { index in
                        HStack(spacing: 4) {
                            if index.isPrimary {
                                Image(systemName: "key.fill")
                                    .foregroundColor(.yellow)
                                    .font(.caption)
                            } else if index.isUnique {
                                Image(systemName: "seal.fill")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                            }
                            Text(index.name)
                                .fontWeight(index.isPrimary ? .semibold : .regular)
                        }
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Columns") { index in
                        Text(index.columns.joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 150, ideal: 250)

                    TableColumn("Type") { index in
                        Text(index.type)
                            .foregroundColor(.secondary)
                    }
                    .width(80)

                    TableColumn("Unique") { index in
                        Image(systemName: index.isUnique ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(index.isUnique ? .green : .secondary)
                    }
                    .width(60)
                }
            }
        }
    }

    // MARK: - Foreign Keys Tab

    private var foreignKeysTable: some View {
        Group {
            if foreignKeys.isEmpty {
                emptyState("No foreign keys found")
            } else {
                Table(foreignKeys) {
                    TableColumn("Name") { fk in
                        Text(fk.name)
                            .fontWeight(.medium)
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Column") { fk in
                        Text(fk.column)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("References") { fk in
                        HStack(spacing: 2) {
                            Text(fk.referencedTable)
                                .foregroundColor(.blue)
                            Text(".")
                                .foregroundColor(.secondary)
                            Text(fk.referencedColumn)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("On Delete") { fk in
                        Text(fk.onDelete)
                            .foregroundColor(fk.onDelete == "CASCADE" ? .orange : .secondary)
                    }
                    .width(90)

                    TableColumn("On Update") { fk in
                        Text(fk.onUpdate)
                            .foregroundColor(fk.onUpdate == "CASCADE" ? .orange : .secondary)
                    }
                    .width(90)
                }
            }
        }
    }

    // MARK: - DDL Tab

    private var ddlView: some View {
        VStack(spacing: 0) {
            // Enhanced toolbar with font controls
            HStack(spacing: 12) {
                // Font size controls
                HStack(spacing: 4) {
                    Button(action: { ddlFontSize = max(10, ddlFontSize - 1) }) {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .buttonStyle(.borderless)
                    .help("Decrease font size")

                    Text("\(Int(ddlFontSize))")
                        .font(.system(size: DesignConstants.FontSize.small, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 24)

                    Button(action: { ddlFontSize = min(24, ddlFontSize + 1) }) {
                        Image(systemName: "textformat.size.larger")
                    }
                    .buttonStyle(.borderless)
                    .help("Increase font size")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

                Spacer()

                // Copy confirmation overlay
                if showCopyConfirmation {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Copied!")
                            .font(.system(size: DesignConstants.FontSize.medium, weight: .medium))
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                // Action buttons
                HStack(spacing: 8) {
                    Button(action: copyDDL) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("Copy DDL to clipboard")

                    Button(action: exportDDL) {
                        Label("Export", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .help("Export DDL to file")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, DesignConstants.Spacing.sm)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // DDL text view
            if ddlStatement.isEmpty {
                emptyState("No DDL available")
            } else {
                DDLTextView(ddl: ddlStatement, fontSize: $ddlFontSize)
            }
        }
    }

    // MARK: - DDL Actions

    private func copyDDL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ddlStatement, forType: .string)

        // Show confirmation feedback
        withAnimation(.spring(duration: 0.3)) {
            showCopyConfirmation = true
        }

        // Hide after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(duration: 0.3)) {
                showCopyConfirmation = false
            }
        }
    }

    private func exportDDL() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.init(filenameExtension: "sql")!]
        savePanel.nameFieldStringValue = "\(tableName).sql"
        savePanel.message = "Export DDL Statement"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            do {
                try ddlStatement.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to export DDL: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Empty State

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(message)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load Data (Lazy Loading)

    /// Load only columns on initial view (default tab)
    private func loadColumns() async {
        isLoading = true
        errorMessage = nil

        guard let driver = DatabaseManager.shared.activeDriver else {
            errorMessage = "Not connected"
            isLoading = false
            return
        }

        do {
            columns = try await driver.fetchColumns(table: tableName)
            loadedTabs.insert(.columns)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Load data for tab only when selected (lazy loading)
    private func loadTabDataIfNeeded(_ tab: StructureTab) async {
        // Skip if already loaded
        guard !loadedTabs.contains(tab) else { return }

        guard let driver = DatabaseManager.shared.activeDriver else { return }

        do {
            switch tab {
            case .columns:
                if columns.isEmpty {
                    columns = try await driver.fetchColumns(table: tableName)
                }
            case .indexes:
                indexes = try await driver.fetchIndexes(table: tableName)
            case .foreignKeys:
                foreignKeys = try await driver.fetchForeignKeys(table: tableName)
            case .ddl:
                ddlStatement = try await driver.fetchTableDDL(table: tableName)
            }
            loadedTabs.insert(tab)
        } catch {
            // Log errors for debugging
            print("[TableStructureView] Failed to load \(tab): \(error.localizedDescription)")
        }
    }
}

#Preview {
    TableStructureView(
        tableName: "users",
        connection: DatabaseConnection(
            name: "Test",
            host: "localhost",
            port: 3_306,
            database: "test",
            username: "root",
            type: .mysql
        )
    )
    .frame(width: 800, height: 400)
}
