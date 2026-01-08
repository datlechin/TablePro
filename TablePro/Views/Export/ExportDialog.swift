//
//  ExportDialog.swift
//  TablePro
//
//  Main export dialog for exporting tables to CSV, JSON, or SQL formats.
//  Features a split layout with table selection tree on the left and format options on the right.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Main export dialog view
struct ExportDialog: View {
    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let preselectedTables: Set<String>

    // MARK: - State

    @State private var config = ExportConfiguration()
    @State private var databaseItems: [ExportDatabaseItem] = []
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showProgressDialog = false
    @State private var showSuccessDialog = false
    @State private var exportedFileURL: URL?
    @State private var currentExportTable = ""

    // MARK: - User Preferences

    @AppStorage("hideExportSuccessDialog") private var hideSuccessDialog = false

    // MARK: - Export Service

    @StateObject private var exportServiceState = ExportServiceState()

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Content
            HStack(spacing: 0) {
                // Left: Table tree view
                tableSelectionView
                    .frame(width: leftPanelWidth)

                Divider()

                // Right: Export options
                exportOptionsView
                    .frame(width: 280)
            }
            .frame(height: 420)

            Divider()

            // Footer
            footerView
        }
        .frame(width: dialogWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loadDatabaseItems()
        }
        .onExitCommand {
            if !isExporting {
                isPresented = false
            }
        }
        .alert("Export Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showProgressDialog) {
            ExportProgressView(
                tableName: exportServiceState.currentTable,
                tableIndex: exportServiceState.currentTableIndex,
                totalTables: exportServiceState.totalTables,
                processedRows: exportServiceState.processedRows,
                totalRows: exportServiceState.totalRows,
                statusMessage: exportServiceState.statusMessage
            )                {
                exportServiceState.service?.cancelExport()
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showSuccessDialog) {
            ExportSuccessView(
                onOpenFolder: {
                    openContainingFolder()
                    showSuccessDialog = false
                    isPresented = false
                },
                onClose: {
                    showSuccessDialog = false
                    isPresented = false
                }
            )
        }
    }

    // MARK: - Layout Constants

    private var leftPanelWidth: CGFloat {
        config.format == .sql ? 380 : 240
    }

    private var dialogWidth: CGFloat {
        leftPanelWidth + 280
    }

    // MARK: - Table Selection View

    private var tableSelectionView: some View {
        VStack(spacing: 0) {
            // Header with title and selection count
            HStack {
                Text("Items")
                    .font(.system(size: DesignConstants.FontSize.small, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                // Format-specific column headers for SQL
                if config.format == .sql {
                    Text("Structure")
                        .font(.system(size: DesignConstants.FontSize.small, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .center)

                    Text("Drop")
                        .font(.system(size: DesignConstants.FontSize.small, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .center)

                    Text("Data")
                        .font(.system(size: DesignConstants.FontSize.small, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .center)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Tree view or loading indicator
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading databases...")
                        .font(.system(size: DesignConstants.FontSize.small))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else {
                ExportTableOutlineView(
                    databaseItems: $databaseItems,
                    format: config.format
                )
                .frame(minHeight: 300, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Export Options View

    private var exportOptionsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Format picker with selection count
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()

                    Picker("", selection: $config.format) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)

                    Spacer()
                }

                // Selection count (shows exportable count for SQL format when some tables have no options)
                VStack(spacing: 2) {
                    Text("\(exportableCount) table\(exportableCount == 1 ? "" : "s") to export")
                        .font(.system(size: DesignConstants.FontSize.small))
                        .foregroundStyle(.secondary)

                    // Show warning if some selected tables will be skipped (SQL format only)
                    if config.format == .sql && exportableCount < selectedCount {
                        Text("\(selectedCount - exportableCount) skipped (no options)")
                            .font(.system(size: DesignConstants.FontSize.small))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Format-specific options
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch config.format {
                    case .csv:
                        ExportCSVOptionsView(options: $config.csvOptions)
                    case .json:
                        ExportJSONOptionsView(options: $config.jsonOptions)
                    case .sql:
                        ExportSQLOptionsView(options: $config.sqlOptions)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Spacer(minLength: 0)

            Divider()

            // File name section
            VStack(alignment: .leading, spacing: 6) {
                Text("File name")
                    .font(.system(size: DesignConstants.FontSize.small))
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    TextField("export", text: $config.fileName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: DesignConstants.FontSize.body))

                    Text(".\(fileExtension)")
                        .foregroundStyle(.secondary)
                        .font(.system(size: DesignConstants.FontSize.body, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize()
                }

                // Show validation error if filename is invalid
                if let validationError = fileNameValidationError {
                    Text(validationError)
                        .font(.system(size: DesignConstants.FontSize.small))
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isExporting)

            Spacer()

            if isExporting {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)

                    Text(currentExportTable)
                        .font(.system(size: DesignConstants.FontSize.small))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120)
                }
            }

            Button("Export...") {
                performExport()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(exportableCount == 0 || isExporting || !isFileNameValid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Computed Properties

    private var selectedCount: Int {
        databaseItems.reduce(0) { $0 + $1.selectedCount }
    }

    private var selectedTables: [ExportTableItem] {
        databaseItems.flatMap { $0.selectedTables }
    }

    /// Tables that will actually be exported (filters out SQL tables with no options enabled)
    private var exportableTables: [ExportTableItem] {
        let tables = selectedTables
        // For SQL format, filter out tables with all options disabled (no output would be generated)
        if config.format == .sql {
            return tables.filter { $0.sqlOptions.hasAnyOption }
        }
        return tables
    }

    /// Count of tables that will actually produce output
    private var exportableCount: Int {
        exportableTables.count
    }

    private var fileExtension: String {
        if config.format == .sql && config.sqlOptions.compressWithGzip {
            return "sql.gz"
        }
        return config.format.fileExtension
    }

    /// Windows reserved device names (case-insensitive)
    private static let windowsReservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    ]

    /// Returns a validation error message if the filename is invalid, nil if valid
    private var fileNameValidationError: String? {
        let name = config.fileName.trimmingCharacters(in: .whitespaces)

        if name.isEmpty {
            return "Filename cannot be empty"
        }

        // Invalid filesystem characters (covers macOS, Windows, and Linux)
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        if name.rangeOfCharacter(from: invalidChars) != nil {
            return "Filename contains invalid characters: / \\ : * ? \" < > |"
        }

        // Prevent path traversal attempts and special directory names
        if name == "." || name == ".." ||
            name.hasPrefix("../") || name.hasPrefix("..\\") ||
            name.hasSuffix("/..") || name.hasSuffix("\\..") ||
            name.contains("/../") || name.contains("\\..\\") {
            return "Filename cannot be '.' or '..' or contain path traversal"
        }

        // Check for Windows reserved device names (case-insensitive)
        let baseName = name.components(separatedBy: ".").first ?? name
        if Self.windowsReservedNames.contains(baseName.uppercased()) {
            return "'\(baseName)' is a reserved Windows device name"
        }

        // Check filename length (255 bytes is common limit on most filesystems)
        if name.utf8.count > 255 {
            return "Filename is too long (max 255 bytes)"
        }

        return nil
    }

    /// Validates that the filename is not empty and contains no invalid filesystem characters
    private var isFileNameValid: Bool {
        fileNameValidationError == nil
    }

    // MARK: - Actions

    @MainActor
    private func loadDatabaseItems() async {
        guard let driver = DatabaseManager.shared.activeDriver else {
            isLoading = false
            errorMessage = "Not connected to database"
            showError = true
            return
        }

        do {
            var items: [ExportDatabaseItem] = []

            switch connection.type {
            case .postgresql:
                // PostgreSQL: fetch schemas within current database (can't query across databases)
                let schemas = try await fetchPostgreSQLSchemas(driver: driver)
                for schema in schemas {
                    let tables = try await fetchTablesForSchema(schema, driver: driver)
                    let tableItems = tables.map { table in
                        ExportTableItem(
                            name: table.name,
                            databaseName: schema,  // schema name for PostgreSQL
                            type: table.type,
                            isSelected: schema == "public" && preselectedTables.contains(table.name)
                        )
                    }
                    if !tableItems.isEmpty {
                        items.append(ExportDatabaseItem(
                            name: schema,
                            tables: tableItems,
                            isExpanded: schema == "public"
                        ))
                    }
                }
                // Sort: public schema first
                items.sort { item1, item2 in
                    if item1.name == "public" { return true }
                    if item2.name == "public" { return false }
                    return item1.name < item2.name
                }

            case .sqlite:
                // SQLite: only one database, fetch tables directly
                let tables = try await driver.fetchTables()
                let tableItems = tables.map { table in
                    ExportTableItem(
                        name: table.name,
                        databaseName: "",
                        type: table.type,
                        isSelected: preselectedTables.contains(table.name)
                    )
                }
                if !tableItems.isEmpty {
                    items.append(ExportDatabaseItem(
                        name: connection.database.isEmpty ? "main" : connection.database,
                        tables: tableItems,
                        isExpanded: true
                    ))
                }

            case .mysql, .mariadb:
                // MySQL/MariaDB: fetch all databases and their tables
                let databases = try await driver.fetchDatabases()
                for dbName in databases {
                    let tables = try await fetchTablesForDatabase(dbName, driver: driver)
                    let tableItems = tables.map { table in
                        ExportTableItem(
                            name: table.name,
                            databaseName: dbName,
                            type: table.type,
                            isSelected: dbName == connection.database && preselectedTables.contains(table.name)
                        )
                    }
                    if !tableItems.isEmpty {
                        items.append(ExportDatabaseItem(
                            name: dbName,
                            tables: tableItems,
                            isExpanded: dbName == connection.database
                        ))
                    }
                }
                // Sort: current database first
                items.sort { item1, item2 in
                    if item1.name == connection.database { return true }
                    if item2.name == connection.database { return false }
                    return item1.name < item2.name
                }
            }

            databaseItems = items
            isLoading = false

            // Set default filename based on selection
            if preselectedTables.count == 1, let first = preselectedTables.first {
                config.fileName = first
            } else if !connection.database.isEmpty {
                config.fileName = connection.database
            }
        } catch {
            isLoading = false
            errorMessage = "Failed to load databases: \(error.localizedDescription)"
            showError = true
        }
    }

    private func fetchPostgreSQLSchemas(driver: DatabaseDriver) async throws -> [String] {
        let query = """
            SELECT schema_name
            FROM information_schema.schemata
            WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
            ORDER BY schema_name
            """
        let result = try await driver.execute(query: query)
        return result.rows.compactMap { $0[0] }
    }

    private func fetchTablesForSchema(_ schema: String, driver: DatabaseDriver) async throws -> [TableInfo] {
        // Fetch tables from information_schema and filter by schema in Swift to avoid SQL interpolation.
        let query = """
            SELECT table_schema, table_name, table_type
            FROM information_schema.tables
            ORDER BY table_name
            """
        let result = try await driver.execute(query: query)
        return result.rows.compactMap { row in
            // Expect: [table_schema, table_name, table_type]
            guard row.count >= 2,
                  let rowSchema = row[0],
                  rowSchema == schema,
                  let name = row[1] else {
                return nil
            }
            let typeStr = row.count > 2 ? (row[2] ?? "BASE TABLE") : "BASE TABLE"
            let type: TableInfo.TableType = typeStr.uppercased().contains("VIEW") ? .view : .table
            return TableInfo(name: name, type: type, rowCount: nil)
        }
    }

    private func fetchTablesForDatabase(_ database: String, driver: DatabaseDriver) async throws -> [TableInfo] {
        // Fetch tables from information_schema and filter by database in Swift to avoid SQL interpolation.
        // MySQL/MariaDB: information_schema.TABLES contains TABLE_SCHEMA, TABLE_NAME, and TABLE_TYPE.
        let query = """
            SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE
            FROM information_schema.TABLES
            ORDER BY TABLE_NAME
            """
        let result = try await driver.execute(query: query)

        return result.rows.compactMap { row in
            // Expect: [TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE]
            guard row.count >= 2,
                  let rowSchema = row[0],
                  rowSchema == database,
                  let name = row[1] else {
                return nil
            }
            let typeStr = row.count > 2 ? (row[2] ?? "BASE TABLE") : "BASE TABLE"
            let type: TableInfo.TableType = typeStr.uppercased().contains("VIEW") ? .view : .table
            return TableInfo(name: name, type: type, rowCount: nil)
        }
    }

    private func performExport() {
        // Show save panel
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.showsTagField = false

        // Configure allowed file types
        if config.format == .sql && config.sqlOptions.compressWithGzip {
            savePanel.allowedContentTypes = [UTType(filenameExtension: "gz") ?? .data]
            savePanel.nameFieldStringValue = "\(config.fileName).sql.gz"
        } else {
            let utType = UTType(filenameExtension: config.format.fileExtension) ?? .plainText
            savePanel.allowedContentTypes = [utType]
            savePanel.nameFieldStringValue = config.fullFileName
        }

        savePanel.message = "Export \(exportableCount) table(s) to \(config.format.rawValue)"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            Task {
                await startExport(to: url)
            }
        }
    }

    @MainActor
    private func startExport(to url: URL) async {
        guard let driver = DatabaseManager.shared.activeDriver else {
            errorMessage = "Not connected to database"
            showError = true
            return
        }

        isExporting = true
        exportedFileURL = url

        let service = ExportService(
            driver: driver,
            databaseType: connection.type
        )
        exportServiceState.service = service

        // Show progress dialog
        showProgressDialog = true

        do {
            try await service.export(
                tables: exportableTables,
                config: config,
                to: url
            )

            // Export completed successfully
            showProgressDialog = false
            isExporting = false

            // Show success dialog or close directly based on preference
            if hideSuccessDialog {
                isPresented = false
            } else {
                showSuccessDialog = true
            }
        } catch {
            showProgressDialog = false
            isExporting = false
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func openContainingFolder() {
        guard let url = exportedFileURL else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }
}

// MARK: - Export Service State

/// Observable wrapper for ExportService to enable SwiftUI bindings
@MainActor
final class ExportServiceState: ObservableObject {
    @Published var currentTable: String = ""
    @Published var currentTableIndex: Int = 0
    @Published var totalTables: Int = 0
    @Published var processedRows: Int = 0
    @Published var totalRows: Int = 0
    @Published var statusMessage: String = ""

    private var cancellables = Set<AnyCancellable>()

    var service: ExportService? {
        didSet {
            cancellables.removeAll()
            guard let service = service else { return }

            service.$currentTable
                .receive(on: DispatchQueue.main)
                .assign(to: &$currentTable)

            service.$currentTableIndex
                .receive(on: DispatchQueue.main)
                .assign(to: &$currentTableIndex)

            service.$totalTables
                .receive(on: DispatchQueue.main)
                .assign(to: &$totalTables)

            service.$processedRows
                .receive(on: DispatchQueue.main)
                .assign(to: &$processedRows)

            service.$totalRows
                .receive(on: DispatchQueue.main)
                .assign(to: &$totalRows)

            service.$statusMessage
                .receive(on: DispatchQueue.main)
                .assign(to: &$statusMessage)
        }
    }
}

// MARK: - Preview

#Preview {
    let connection = DatabaseConnection(
        name: "Local MySQL",
        host: "localhost",
        database: "my_database",
        type: .mysql
    )

    return ExportDialog(
        isPresented: .constant(true),
        connection: connection,
        preselectedTables: ["users"]
    )
}
