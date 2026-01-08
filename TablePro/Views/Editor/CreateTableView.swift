//
//  CreateTableView.swift
//  TablePro
//
//  Modern redesigned table creation interface with TablePlus-inspired UI/UX.
//  Features table-style column editor, side panel, and professional styling.
//

import SwiftUI
import UniformTypeIdentifiers

struct CreateTableView: View {
    @Binding var options: TableCreationOptions
    let databaseType: DatabaseType
    let onCancel: () -> Void
    let onCreate: (TableCreationOptions) -> Void

    @State private var selectedColumnId: UUID?
    @State private var showDetailPanel = false
    @State private var showAdvancedOptions = false
    @State private var showSQLPreview = false
    @State private var showForeignKeys = false
    @State private var showIndexes = false
    @State private var showCheckConstraints = false
    @State private var validationError: String?
    @State private var showSaveTemplate = false
    @State private var showLoadTemplate = false
    @State private var templateName = ""
    @State private var savedTemplates: [String] = []
    @State private var showImportDDL = false
    @State private var ddlText = ""
    @State private var showDuplicateTable = false
    @State private var availableTables: [String] = []
    @State private var selectedTableToDuplicate: String?

    private let service: CreateTableService

    init(
        options: Binding<TableCreationOptions>,
        databaseType: DatabaseType,
        onCancel: @escaping () -> Void,
        onCreate: @escaping (TableCreationOptions) -> Void
    ) {
        self._options = options
        self.databaseType = databaseType
        self.onCancel = onCancel
        self.onCreate = onCreate
        self.service = CreateTableService(databaseType: databaseType)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main content
            mainContent
                .frame(maxWidth: .infinity)

            // Detail panel (slides in from right)
            if showDetailPanel, let selectedId = selectedColumnId,
               let columnIndex = options.columns.firstIndex(where: { $0.id == selectedId }) {
                ColumnDetailPanel(
                    column: $options.columns[columnIndex],
                    databaseType: databaseType,
                    isVisible: showDetailPanel
                )                    {
                    showDetailPanel = false
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: DesignConstants.AnimationDuration.smooth), value: showDetailPanel)
        .background(Color(nsColor: .textBackgroundColor))
        .onKeyPress(.escape) {
            if showDetailPanel {
                showDetailPanel = false
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar

            Divider()

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.md) {
                    // General info
                    generalSection

                    // Columns (table-style)
                    columnsSection

                    // Primary key
                    primaryKeySection

                    // Foreign keys
                    foreignKeysSection

                    // Indexes
                    indexesSection

                    // Check constraints (PostgreSQL/SQLite)
                    if databaseType == .postgresql || databaseType == .sqlite {
                        checkConstraintsSection
                    }

                    // Advanced options
                    advancedSection

                    // SQL Preview
                    sqlPreviewSection
                }
                .padding(DesignConstants.Spacing.md)
            }

            Divider()

            // Footer
            footer
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: DesignConstants.Spacing.sm) {
            Text("Create New Table")
                .font(.system(size: DesignConstants.FontSize.title3, weight: .semibold))

            Spacer()

            // Error message
            if let error = validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: DesignConstants.FontSize.caption))
                    .foregroundStyle(.red)
            }

            // Template actions
            Button(action: {
                savedTemplates = TableTemplateStorage.shared.getTemplateNames()
                showLoadTemplate = true
            }) {
                Label("Load", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Load Template")
            .disabled(TableTemplateStorage.shared.getTemplateNames().isEmpty)

            Button(action: { showSaveTemplate = true }) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Save as Template")

            Divider()
                .frame(height: 16)

            // Import actions
            Button(action: { showImportDDL = true }) {
                Label("Import", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Import from DDL")

            Button(action: {
                loadAvailableTables()
                showDuplicateTable = true
            }) {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Duplicate Existing Table")
        }
        .padding(.horizontal, DesignConstants.Spacing.md)
        .padding(.vertical, DesignConstants.Spacing.sm)
        .background(DesignConstants.Colors.sectionBackground.opacity(0.3))
        .sheet(isPresented: $showSaveTemplate) {
            SaveTemplateSheet(
                templateName: $templateName,
                onSave: { saveTemplate(); showSaveTemplate = false },
                onCancel: { showSaveTemplate = false }
            )
        }
        .sheet(isPresented: $showLoadTemplate) {
            LoadTemplateSheet(
                templates: savedTemplates,
                onLoad: { name in loadTemplate(name); showLoadTemplate = false },
                onDelete: deleteTemplate
            )                   { showLoadTemplate = false }
        }
        .sheet(isPresented: $showImportDDL) {
            ImportDDLSheet(
                ddlText: $ddlText,
                onImport: { importDDL(); showImportDDL = false },
                onCancel: { showImportDDL = false }
            )
        }
        .sheet(isPresented: $showDuplicateTable) {
            DuplicateTableSheet(
                tables: availableTables,
                selectedTable: $selectedTableToDuplicate,
                onDuplicate: {
                    if let selected = selectedTableToDuplicate {
                        duplicateTable(selected)
                    }
                    showDuplicateTable = false
                },
                onCancel: { showDuplicateTable = false }
            )
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.sm) {
                TextField("Table Name", text: $options.tableName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("Database/Schema:")
                        .font(.system(size: DesignConstants.FontSize.small))
                        .foregroundStyle(DesignConstants.Colors.secondaryText)
                    Text(options.databaseName)
                        .font(.system(size: DesignConstants.FontSize.small))
                        .foregroundStyle(DesignConstants.Colors.tertiaryText)
                }
            }
            .padding(DesignConstants.Spacing.sm)
            .background(DesignConstants.Colors.sectionBackground)
            .cornerRadius(DesignConstants.CornerRadius.medium)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
            SectionHeaderView(
                title: "Advanced Options",
                isCollapsible: true,
                isExpanded: $showAdvancedOptions
            )

            if showAdvancedOptions {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.sm) {
                    if databaseType == .mysql || databaseType == .mariadb {
                        TextField("Engine (e.g., InnoDB)", text: Binding(
                            get: { options.engine ?? "" },
                            set: { options.engine = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        TextField("Charset (e.g., utf8mb4)", text: Binding(
                            get: { options.charset ?? "" },
                            set: { options.charset = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        TextField("Collation", text: Binding(
                            get: { options.collation ?? "" },
                            set: { options.collation = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    if databaseType == .postgresql {
                        TextField("Tablespace", text: Binding(
                            get: { options.tablespace ?? "" },
                            set: { options.tablespace = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    TextField("Comment", text: Binding(
                        get: { options.comment ?? "" },
                        set: { options.comment = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                .padding(DesignConstants.Spacing.sm)
                .background(DesignConstants.Colors.sectionBackground)
                .cornerRadius(DesignConstants.CornerRadius.medium)
            }
        }
    }

    private var columnsSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
            SectionHeaderView(title: "Columns", count: options.columns.count) {
                HStack(spacing: DesignConstants.Spacing.xs) {
                    Menu {
                        ForEach(ColumnTemplate.allCases) { template in
                            Button(template.rawValue) {
                                addColumnFromTemplate(template)
                            }
                        }
                    } label: {
                        Label("Template", systemImage: "wand.and.stars")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)

                    Button(action: addColumn) {
                        Label("Add Column", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            ColumnTableView(
                columns: $options.columns,
                primaryKeyColumns: $options.primaryKeyColumns,
                selectedColumnId: $selectedColumnId,
                databaseType: databaseType,
                onDelete: deleteColumn,
                onMoveUp: moveColumnUp,
                onMoveDown: moveColumnDown
            )                { column in
                selectedColumnId = column.id
                showDetailPanel = true
            }
        }
    }

    private var primaryKeySection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
            SectionHeaderView(title: "Primary Key")

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.sm) {
                if options.columns.isEmpty {
                    Text("Add columns first")
                        .font(.system(size: DesignConstants.FontSize.small))
                        .foregroundStyle(DesignConstants.Colors.tertiaryText)
                        .padding(DesignConstants.Spacing.sm)
                } else {
                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
                        ForEach(options.columns) { column in
                            Toggle(isOn: Binding(
                                get: { options.primaryKeyColumns.contains(column.name) },
                                set: { isOn in
                                    if isOn {
                                        if !options.primaryKeyColumns.contains(column.name) {
                                            options.primaryKeyColumns.append(column.name)
                                        }
                                    } else {
                                        options.primaryKeyColumns.removeAll { $0 == column.name }
                                    }
                                }
                            )) {
                                Text(column.name.isEmpty ? "(unnamed)" : column.name)
                                    .font(.system(size: DesignConstants.FontSize.small))
                            }
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .disabled(column.name.isEmpty)
                        }
                    }

                    if options.primaryKeyColumns.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: DesignConstants.FontSize.caption))
                            Text("No primary key selected (not recommended)")
                                .font(.system(size: DesignConstants.FontSize.caption))
                        }
                        .foregroundStyle(.orange)
                    }
                }
            }
            .padding(DesignConstants.Spacing.sm)
            .background(DesignConstants.Colors.sectionBackground)
            .cornerRadius(DesignConstants.CornerRadius.medium)
        }
    }

    private var foreignKeysSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
            SectionHeaderView(
                title: "Foreign Keys",
                count: options.foreignKeys.count,
                isCollapsible: true,
                isExpanded: $showForeignKeys
            ) {
                Button(action: {
                    options.foreignKeys.append(ForeignKeyConstraint())
                    showForeignKeys = true
                }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if showForeignKeys {
                if options.foreignKeys.isEmpty {
                    VStack(spacing: DesignConstants.Spacing.sm) {
                        Button(action: { options.foreignKeys.append(ForeignKeyConstraint()) }) {
                            Label("Add Foreign Key", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(DesignConstants.Spacing.sm)
                    .background(DesignConstants.Colors.sectionBackground)
                    .cornerRadius(DesignConstants.CornerRadius.medium)
                } else {
                    VStack(spacing: DesignConstants.Spacing.xs) {
                        ForEach(options.foreignKeys) { fk in
                            ForeignKeyRow(
                                foreignKey: Binding(
                                    get: { fk },
                                    set: { newValue in
                                        if let index = options.foreignKeys.firstIndex(where: { $0.id == fk.id }) {
                                            options.foreignKeys[index] = newValue
                                        }
                                    }
                                ),
                                availableColumns: options.columns.map { $0.name }
                            )                                   { options.foreignKeys.removeAll { $0.id == fk.id } }
                        }
                    }
                }
            }
        }
    }

    private var indexesSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
            SectionHeaderView(
                title: "Indexes",
                count: options.indexes.count,
                isCollapsible: true,
                isExpanded: $showIndexes
            ) {
                Button(action: {
                    options.indexes.append(IndexDefinition())
                    showIndexes = true
                }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if showIndexes {
                if options.indexes.isEmpty {
                    VStack(spacing: DesignConstants.Spacing.sm) {
                        Button(action: { options.indexes.append(IndexDefinition()) }) {
                            Label("Add Index", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(DesignConstants.Spacing.sm)
                    .background(DesignConstants.Colors.sectionBackground)
                    .cornerRadius(DesignConstants.CornerRadius.medium)
                } else {
                    VStack(spacing: DesignConstants.Spacing.xs) {
                        ForEach(options.indexes) { index in
                            IndexRow(
                                index: Binding(
                                    get: { index },
                                    set: { newValue in
                                        if let idx = options.indexes.firstIndex(where: { $0.id == index.id }) {
                                            options.indexes[idx] = newValue
                                        }
                                    }
                                ),
                                availableColumns: options.columns.map { $0.name },
                                databaseType: databaseType
                            )                                   { options.indexes.removeAll { $0.id == index.id } }
                        }
                    }
                }
            }
        }
    }

    private var checkConstraintsSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
            SectionHeaderView(
                title: "Check Constraints",
                count: options.checkConstraints.count,
                isCollapsible: true,
                isExpanded: $showCheckConstraints
            ) {
                Button(action: {
                    options.checkConstraints.append(CheckConstraint())
                    showCheckConstraints = true
                }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if showCheckConstraints {
                if options.checkConstraints.isEmpty {
                    VStack(spacing: DesignConstants.Spacing.sm) {
                        Button(action: { options.checkConstraints.append(CheckConstraint()) }) {
                            Label("Add Check Constraint", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(DesignConstants.Spacing.sm)
                    .background(DesignConstants.Colors.sectionBackground)
                    .cornerRadius(DesignConstants.CornerRadius.medium)
                } else {
                    VStack(spacing: DesignConstants.Spacing.xs) {
                        ForEach(options.checkConstraints) { check in
                            CheckConstraintRow(
                                constraint: Binding(
                                    get: { check },
                                    set: { newValue in
                                        if let idx = options.checkConstraints.firstIndex(where: { $0.id == check.id }) {
                                            options.checkConstraints[idx] = newValue
                                        }
                                    }
                                )
                            )                                   { options.checkConstraints.removeAll { $0.id == check.id } }
                        }
                    }
                }
            }
        }
    }

    private var sqlPreviewSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.xs) {
            SectionHeaderView(
                title: "SQL Preview",
                isCollapsible: true,
                isExpanded: $showSQLPreview
            ) {
                Button(action: copySQLToClipboard) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy SQL")
            }

            if showSQLPreview {
                ScrollView {
                    Text(service.generatePreviewSQL(options))
                        .font(.system(size: DesignConstants.FontSize.small, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignConstants.Spacing.sm)
                }
                .frame(maxHeight: 200)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(DesignConstants.CornerRadius.medium)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                        .stroke(DesignConstants.Colors.border, lineWidth: 0.5)
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.escape)

            Button("Create Table") {
                createTable()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!options.isValid)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(DesignConstants.Spacing.sm)
    }

    // MARK: - Actions

    private func addColumn() {
        let newColumn = ColumnDefinition(
            name: "column_\(options.columns.count + 1)",
            dataType: "VARCHAR",
            length: 255
        )
        options.columns.append(newColumn)
        selectedColumnId = newColumn.id
    }

    private func addColumnFromTemplate(_ template: ColumnTemplate) {
        let newColumn = template.createColumn(for: databaseType)
        options.columns.append(newColumn)
        selectedColumnId = newColumn.id
    }

    private func deleteColumn(_ column: ColumnDefinition) {
        options.primaryKeyColumns.removeAll { $0 == column.name }
        options.columns.removeAll { $0.id == column.id }
        if selectedColumnId == column.id {
            selectedColumnId = options.columns.first?.id
        }
    }

    private func moveColumnUp(_ column: ColumnDefinition) {
        guard let index = options.columns.firstIndex(where: { $0.id == column.id }), index > 0 else { return }
        options.columns.swapAt(index, index - 1)
    }

    private func moveColumnDown(_ column: ColumnDefinition) {
        guard let index = options.columns.firstIndex(where: { $0.id == column.id }),
              index < options.columns.count - 1 else { return }
        options.columns.swapAt(index, index + 1)
    }

    private func createTable() {
        do {
            try service.validate(options)
            validationError = nil
            onCreate(options)
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func saveTemplate() {
        guard !templateName.isEmpty else { return }
        do {
            try TableTemplateStorage.shared.saveTemplate(name: templateName, options: options)
            templateName = ""
        } catch {
            validationError = "Failed to save template: \(error.localizedDescription)"
        }
    }

    private func loadTemplate(_ name: String) {
        do {
            if let loaded = try TableTemplateStorage.shared.loadTemplate(name: name) {
                let currentDB = options.databaseName
                let currentTable = options.tableName
                options = loaded
                options.databaseName = currentDB
                options.tableName = currentTable.isEmpty ? loaded.tableName : currentTable
                selectedColumnId = options.columns.first?.id
            }
        } catch {
            validationError = "Failed to load template: \(error.localizedDescription)"
        }
    }

    private func deleteTemplate(_ name: String) {
        do {
            try TableTemplateStorage.shared.deleteTemplate(name: name)
            savedTemplates = TableTemplateStorage.shared.getTemplateNames()
        } catch {
            validationError = "Failed to delete template: \(error.localizedDescription)"
        }
    }

    private func importDDL() {
        do {
            let parsed = try DDLParser.parse(ddlText, databaseType: databaseType)
            let currentDB = options.databaseName
            options = parsed
            options.databaseName = currentDB
            selectedColumnId = options.columns.first?.id
            ddlText = ""
        } catch {
            validationError = "Failed to import DDL: \(error.localizedDescription)"
        }
    }

    private func loadAvailableTables() {
        Task {
            do {
                guard let driver = DatabaseManager.shared.activeDriver else { return }
                let query = switch databaseType {
                case .mysql, .mariadb: "SHOW TABLES"
                case .postgresql: "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
                case .sqlite: "SELECT name FROM sqlite_master WHERE type='table'"
                }
                let result = try await driver.execute(query: query)
                await MainActor.run {
                    availableTables = result.rows.compactMap { $0.first.flatMap { $0 } }
                }
            } catch {
                await MainActor.run {
                    validationError = "Failed to load tables: \(error.localizedDescription)"
                }
            }
        }
    }

    private func duplicateTable(_ tableName: String) {
        Task {
            do {
                guard let driver = DatabaseManager.shared.activeDriver else {
                    await MainActor.run {
                        validationError = "No database connection"
                    }
                    return
                }

                // Query information schema directly instead of parsing DDL
                let columnsQuery: String

                switch databaseType {
                case .mysql, .mariadb:
                    columnsQuery = """
                        SELECT
                            COLUMN_NAME,
                            DATA_TYPE,
                            CHARACTER_MAXIMUM_LENGTH,
                            NUMERIC_PRECISION,
                            NUMERIC_SCALE,
                            IS_NULLABLE,
                            COLUMN_DEFAULT,
                            EXTRA,
                            COLUMN_KEY
                        FROM INFORMATION_SCHEMA.COLUMNS
                        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(tableName)'
                        ORDER BY ORDINAL_POSITION
                    """

                case .postgresql:
                    columnsQuery = """
                        SELECT
                            column_name,
                            data_type,
                            character_maximum_length,
                            numeric_precision,
                            numeric_scale,
                            is_nullable,
                            column_default
                        FROM information_schema.columns
                        WHERE table_name = '\(tableName)'
                        ORDER BY ordinal_position
                    """

                case .sqlite:
                    columnsQuery = "PRAGMA table_info('\(tableName)')"
                }

                let result = try await driver.execute(query: columnsQuery)

                await MainActor.run {
                    guard !result.rows.isEmpty else {
                        validationError = "Table '\(tableName)' has no columns or does not exist"
                        return
                    }

                    // Debug: Log what we got
                    print("DEBUG: Duplicate table - Got \(result.rows.count) rows")
                    print("DEBUG: Columns: \(result.columns)")
                    if let firstRow = result.rows.first {
                        print("DEBUG: First row: \(firstRow)")
                    }

                    // Build arrays locally first (don't modify options until we're done)
                    var newColumns: [ColumnDefinition] = []
                    var newPrimaryKeys: [String] = []
                    var parsedCount = 0

                    // Parse each column
                    for row in result.rows {
                        switch databaseType {
                        case .mysql, .mariadb:
                            guard row.count >= 9,
                                  let columnName = row[0],
                                  let dataType = row[1] else { continue }

                            let length = row[2].flatMap { Int($0) }
                            let precision = row[3].flatMap { Int($0) }
                            let isNullable = row[5] == "YES"
                            let defaultValue = row[6]
                            let extra = row[7] ?? ""
                            let columnKey = row[8] ?? ""

                            let column = ColumnDefinition(
                                name: columnName,
                                dataType: dataType.uppercased(),
                                length: length,
                                precision: precision,
                                notNull: !isNullable,
                                defaultValue: defaultValue,
                                autoIncrement: extra.uppercased().contains("AUTO_INCREMENT")
                            )

                            newColumns.append(column)
                            parsedCount += 1

                            if columnKey == "PRI" {
                                newPrimaryKeys.append(columnName)
                            }

                        case .postgresql:
                            guard row.count >= 7,
                                  let columnName = row[0],
                                  let dataType = row[1] else { continue }

                            let length = row[2].flatMap { Int($0) }
                            let precision = row[3].flatMap { Int($0) }
                            let isNullable = row[5] == "YES"
                            let defaultValue = row[6]

                            let column = ColumnDefinition(
                                name: columnName,
                                dataType: dataType.uppercased(),
                                length: length,
                                precision: precision,
                                notNull: !isNullable,
                                defaultValue: defaultValue
                            )

                            newColumns.append(column)
                            parsedCount += 1

                        case .sqlite:
                            // SQLite PRAGMA format: cid, name, type, notnull, dflt_value, pk
                            guard row.count >= 6,
                                  let columnName = row[1],
                                  let dataType = row[2] else { continue }

                            let notNull = row[3] == "1"
                            let defaultValue = row[4]
                            let isPk = row[5] == "1"

                            let column = ColumnDefinition(
                                name: columnName,
                                dataType: dataType.uppercased(),
                                notNull: notNull,
                                defaultValue: defaultValue
                            )

                            newColumns.append(column)
                            parsedCount += 1

                            if isPk {
                                newPrimaryKeys.append(columnName)
                            }
                        }
                    }

                    // Debug: Log results
                    print("DEBUG: Parsed \(parsedCount) columns out of \(result.rows.count) rows")
                    print("DEBUG: newColumns.count = \(newColumns.count)")
                    print("DEBUG: Primary keys = \(newPrimaryKeys)")

                    guard !newColumns.isEmpty else {
                        validationError = "Failed to parse any columns from table '\(tableName)'. Check console for debug info."
                        return
                    }

                    // Create a completely new TableCreationOptions to avoid binding issues
                    var newOptions = TableCreationOptions()

                    // For PostgreSQL, use current database/schema, for MySQL use DATABASE()
                    // For duplicates, just use the table name without schema prefix
                    if databaseType == .postgresql {
                        // Use "public" as default schema, or current schema
                        newOptions.databaseName = "public"
                    } else {
                        newOptions.databaseName = options.databaseName
                    }

                    newOptions.tableName = "\(tableName)_copy"
                    newOptions.columns = newColumns
                    newOptions.primaryKeyColumns = newPrimaryKeys

                    // Assign the entire new object at once
                    options = newOptions

                    selectedColumnId = options.columns.first?.id
                    validationError = nil

                    print("DEBUG: Duplicate complete - \(options.columns.count) columns copied")
                }
            } catch {
                await MainActor.run {
                    validationError = "Failed to fetch table structure: \(error.localizedDescription)"
                }
            }
        }
    }

    private func copySQLToClipboard() {
        let sql = service.generatePreviewSQL(options)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
    }
}
