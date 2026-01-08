//
//  ExportModels.swift
//  TablePro
//
//  Models for table export functionality.
//  Supports CSV, JSON, and SQL export formats with configurable options.
//

import Foundation

// MARK: - Export Format

/// Supported export file formats
enum ExportFormat: String, CaseIterable, Identifiable {
    case csv = "CSV"
    case json = "JSON"
    case sql = "SQL"

    var id: String { rawValue }

    /// File extension for this format
    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        case .sql: return "sql"
        }
    }
}

// MARK: - CSV Options

/// CSV field delimiter options
enum CSVDelimiter: String, CaseIterable, Identifiable {
    case comma = ","
    case semicolon = ";"
    case tab = "\\t"
    case pipe = "|"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .comma: return ","
        case .semicolon: return ";"
        case .tab: return "\\t"
        case .pipe: return "|"
        }
    }

    /// Actual character(s) to use as delimiter
    var actualValue: String {
        self == .tab ? "\t" : rawValue
    }
}

/// CSV field quoting behavior
enum CSVQuoteHandling: String, CaseIterable, Identifiable {
    case always = "Always"
    case asNeeded = "Quote if needed"
    case never = "Never"

    var id: String { rawValue }
}

/// Line break format for CSV export
enum CSVLineBreak: String, CaseIterable, Identifiable {
    case lf = "\\n"
    case crlf = "\\r\\n"
    case cr = "\\r"

    var id: String { rawValue }

    /// Actual line break characters
    var value: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

/// Decimal separator format
enum CSVDecimalFormat: String, CaseIterable, Identifiable {
    case period = "."
    case comma = ","

    var id: String { rawValue }

    var separator: String { rawValue }
}

/// Options for CSV export
struct CSVExportOptions: Equatable {
    var convertNullToEmpty: Bool = true
    var convertLineBreakToSpace: Bool = false
    var includeFieldNames: Bool = true
    var delimiter: CSVDelimiter = .comma
    var quoteHandling: CSVQuoteHandling = .asNeeded
    var lineBreak: CSVLineBreak = .lf
    var decimalFormat: CSVDecimalFormat = .period
    /// Sanitize formula-like values to prevent CSV formula injection attacks.
    /// When enabled, values starting with =, +, -, @, tab, or carriage return
    /// are prefixed with a single quote to prevent execution in spreadsheet applications.
    var sanitizeFormulas: Bool = true
}

// MARK: - JSON Options

/// Options for JSON export
struct JSONExportOptions: Equatable {
    var prettyPrint: Bool = true
    var includeNullValues: Bool = true
    /// When enabled, all values are exported as strings without type detection.
    /// This preserves leading zeros in ZIP codes, phone numbers, and similar data.
    var preserveAllAsStrings: Bool = false
}

// MARK: - SQL Options

/// Per-table SQL export options (Structure, Drop, Data checkboxes)
struct SQLTableExportOptions: Equatable {
    var includeStructure: Bool = true
    var includeDrop: Bool = true
    var includeData: Bool = true

    /// Returns true if at least one export option is enabled
    var hasAnyOption: Bool {
        includeStructure || includeDrop || includeData
    }
}

/// Global options for SQL export
struct SQLExportOptions: Equatable {
    var compressWithGzip: Bool = false
    /// Number of rows per INSERT statement. Default 500.
    /// Higher values = fewer statements, smaller file, faster import.
    /// Set to 1 for single-row INSERT statements (legacy behavior).
    var batchSize: Int = 500
}

// MARK: - Export Configuration

/// Complete export configuration combining format, selection, and options
struct ExportConfiguration {
    var format: ExportFormat = .csv
    var fileName: String = "export"
    var csvOptions = CSVExportOptions()
    var jsonOptions = JSONExportOptions()
    var sqlOptions = SQLExportOptions()

    /// Full file name including extension
    var fullFileName: String {
        let ext = compressedExtension ?? format.fileExtension
        return "\(fileName).\(ext)"
    }

    private var compressedExtension: String? {
        if format == .sql && sqlOptions.compressWithGzip {
            return "sql.gz"
        }
        return nil
    }
}

// MARK: - Tree View Models

/// Represents a table item in the export tree view
struct ExportTableItem: Identifiable, Hashable {
    let id: UUID
    let name: String
    let databaseName: String
    let type: TableInfo.TableType
    var isSelected: Bool = false
    var sqlOptions = SQLTableExportOptions()

    init(
        id: UUID = UUID(),
        name: String,
        databaseName: String = "",
        type: TableInfo.TableType,
        isSelected: Bool = false,
        sqlOptions: SQLTableExportOptions = SQLTableExportOptions()
    ) {
        self.id = id
        self.name = name
        self.databaseName = databaseName
        self.type = type
        self.isSelected = isSelected
        self.sqlOptions = sqlOptions
    }

    /// Fully qualified table name (database.table)
    var qualifiedName: String {
        databaseName.isEmpty ? name : "\(databaseName).\(name)"
    }

    // Hashable conformance excluding mutable state
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ExportTableItem, rhs: ExportTableItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Represents a database item in the export tree view (contains tables)
struct ExportDatabaseItem: Identifiable {
    let id: UUID
    let name: String
    var tables: [ExportTableItem]
    var isExpanded: Bool = true

    init(
        id: UUID = UUID(),
        name: String,
        tables: [ExportTableItem],
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.tables = tables
        self.isExpanded = isExpanded
    }

    /// Number of selected tables
    var selectedCount: Int {
        tables.filter { $0.isSelected }.count
    }

    /// Whether all tables are selected
    var allSelected: Bool {
        !tables.isEmpty && tables.allSatisfy { $0.isSelected }
    }

    /// Whether no tables are selected
    var noneSelected: Bool {
        tables.allSatisfy { !$0.isSelected }
    }

    /// Get all selected table items
    var selectedTables: [ExportTableItem] {
        tables.filter { $0.isSelected }
    }
}
