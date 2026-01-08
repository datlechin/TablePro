//
//  SQLCompletionItem.swift
//  TablePro
//
//  Model for SQL autocomplete suggestions
//

import AppKit
import Foundation

/// Category of completion item
@MainActor
enum SQLCompletionKind: String, CaseIterable {
    case keyword    // SELECT, FROM, WHERE, etc.
    case table      // Database tables
    case view       // Database views
    case column     // Table columns
    case function   // SQL functions (COUNT, SUM, NOW, etc.)
    case schema     // Database/schema names
    case alias      // Table aliases
    case `operator` // Operators (=, <>, LIKE, etc.)

    /// SF Symbol for display
    var iconName: String {
        switch self {
        case .keyword: return "k.circle.fill"
        case .table: return "tablecells"
        case .view: return "eye"
        case .column: return "c.circle.fill"
        case .function: return "f.circle.fill"
        case .schema: return "cylinder.split.1x2"
        case .alias: return "a.circle.fill"
        case .operator: return "equal.circle.fill"
        }
    }

    /// Color for the icon
    var iconColor: NSColor {
        switch self {
        case .keyword: return .systemBlue
        case .table: return .systemTeal
        case .view: return .systemPurple
        case .column: return .systemOrange
        case .function: return .systemPink
        case .schema: return .systemGreen
        case .alias: return .systemGray
        case .operator: return .systemIndigo
        }
    }

    /// Base sort priority (lower = higher priority in same context)
    var basePriority: Int {
        switch self {
        case .column: return 100
        case .table: return 200
        case .view: return 210
        case .function: return 300
        case .keyword: return 400
        case .alias: return 150
        case .schema: return 500
        case .operator: return 350
        }
    }
}

/// A single completion suggestion
@MainActor
struct SQLCompletionItem: Identifiable, Hashable {
    let id: UUID
    let label: String           // Display text
    let kind: SQLCompletionKind
    let insertText: String      // Text to insert (may differ from label)
    let detail: String?         // Type info, e.g., "VARCHAR(255)"
    let documentation: String?  // Tooltip/description
    var sortPriority: Int       // For ranking (lower = higher priority)
    let filterText: String      // Text used for matching

    init(
        label: String,
        kind: SQLCompletionKind,
        insertText: String? = nil,
        detail: String? = nil,
        documentation: String? = nil,
        sortPriority: Int? = nil,
        filterText: String? = nil
    ) {
        self.id = UUID()
        self.label = label
        self.kind = kind
        self.insertText = insertText ?? label
        self.detail = detail
        self.documentation = documentation
        self.sortPriority = sortPriority ?? kind.basePriority
        self.filterText = filterText ?? label.lowercased()
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(label)
        hasher.combine(kind)
    }

    static func == (lhs: SQLCompletionItem, rhs: SQLCompletionItem) -> Bool {
        lhs.label == rhs.label && lhs.kind == rhs.kind
    }
}

// MARK: - Factory Methods

extension SQLCompletionItem {
    /// Create a keyword completion item
    static func keyword(_ keyword: String, documentation: String? = nil) -> SQLCompletionItem {
        SQLCompletionItem(
            label: keyword.uppercased(),
            kind: .keyword,
            insertText: keyword.uppercased(),
            documentation: documentation
        )
    }

    /// Create a table completion item
    static func table(_ name: String, isView: Bool = false) -> SQLCompletionItem {
        SQLCompletionItem(
            label: name,
            kind: isView ? .view : .table,
            insertText: name,
            detail: isView ? "View" : "Table"
        )
    }

    /// Create a column completion item
    static func column(_ name: String, dataType: String?, tableName: String? = nil) -> SQLCompletionItem {
        SQLCompletionItem(
            label: name,
            kind: .column,
            insertText: name,
            detail: dataType,
            documentation: tableName.map { "Column from \($0)" }
        )
    }

    /// Create a function completion item
    static func function(_ name: String, signature: String? = nil, documentation: String? = nil) -> SQLCompletionItem {
        let insertText = signature != nil ? "\(name)(" : name
        return SQLCompletionItem(
            label: name,
            kind: .function,
            insertText: insertText,
            detail: signature,
            documentation: documentation
        )
    }

    /// Create an operator completion item
    static func `operator`(_ op: String, documentation: String? = nil) -> SQLCompletionItem {
        SQLCompletionItem(
            label: op,
            kind: .operator,
            insertText: op,
            documentation: documentation
        )
    }
}
