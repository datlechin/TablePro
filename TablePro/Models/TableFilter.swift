//
//  TableFilter.swift
//  TablePro
//
//  Model for table data filtering
//

import Foundation

/// Represents a filter operator for WHERE clause generation
enum FilterOperator: String, CaseIterable, Identifiable, Codable {
    case equal = "="
    case notEqual = "!="
    case contains = "CONTAINS"
    case notContains = "NOT CONTAINS"
    case startsWith = "STARTS WITH"
    case endsWith = "ENDS WITH"
    case greaterThan = ">"
    case greaterOrEqual = ">="
    case lessThan = "<"
    case lessOrEqual = "<="
    case isNull = "IS NULL"
    case isNotNull = "IS NOT NULL"
    case isEmpty = "IS EMPTY"
    case isNotEmpty = "IS NOT EMPTY"
    case inList = "IN"
    case notInList = "NOT IN"
    case between = "BETWEEN"
    case regex = "REGEX"

    var id: String { rawValue }

    /// Whether this operator requires a value input
    var requiresValue: Bool {
        switch self {
        case .isNull, .isNotNull, .isEmpty, .isNotEmpty:
            return false
        default:
            return true
        }
    }

    /// Whether this operator requires two values (for BETWEEN)
    var requiresSecondValue: Bool {
        self == .between
    }

    /// Display name for UI
    var displayName: String {
        switch self {
        case .equal: return "equals"
        case .notEqual: return "not equals"
        case .contains: return "contains"
        case .notContains: return "not contains"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .greaterThan: return "greater than"
        case .greaterOrEqual: return "greater or equal"
        case .lessThan: return "less than"
        case .lessOrEqual: return "less or equal"
        case .isNull: return "is NULL"
        case .isNotNull: return "is not NULL"
        case .isEmpty: return "is empty"
        case .isNotEmpty: return "is not empty"
        case .inList: return "in list"
        case .notInList: return "not in list"
        case .between: return "between"
        case .regex: return "matches regex"
        }
    }
}

/// Represents a single table filter condition
struct TableFilter: Identifiable, Equatable, Codable {
    let id: UUID
    var columnName: String          // Column to filter on, or "__RAW__" for raw SQL
    var filterOperator: FilterOperator
    var value: String
    var secondValue: String?        // For BETWEEN operator
    var isSelected: Bool            // For multi-select apply
    var isEnabled: Bool             // Whether filter is active
    var rawSQL: String?             // For raw SQL mode

    /// Special column name for raw SQL mode
    static let rawSQLColumn = "__RAW__"

    init(
        id: UUID = UUID(),
        columnName: String = "",
        filterOperator: FilterOperator = .equal,
        value: String = "",
        secondValue: String? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        rawSQL: String? = nil
    ) {
        self.id = id
        self.columnName = columnName
        self.filterOperator = filterOperator
        self.value = value
        self.secondValue = secondValue
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.rawSQL = rawSQL
    }

    /// Whether this filter is valid (has enough info to apply)
    var isValid: Bool {
        if columnName == Self.rawSQLColumn {
            return rawSQL?.isEmpty == false
        }
        guard !columnName.isEmpty else { return false }
        if filterOperator.requiresValue {
            if filterOperator.requiresSecondValue {
                return !value.isEmpty && !(secondValue?.isEmpty ?? true)
            }
            return !value.isEmpty
        }
        return true
    }

    /// Whether this is a raw SQL filter
    var isRawSQL: Bool {
        columnName == Self.rawSQLColumn
    }

    /// Validation error message (nil if valid)
    var validationError: String? {
        if columnName == Self.rawSQLColumn {
            if rawSQL?.isEmpty ?? true {
                return "Raw SQL cannot be empty"
            }
            return nil
        }

        if columnName.isEmpty {
            return "Please select a column"
        }

        if filterOperator.requiresValue {
            if value.isEmpty {
                return "Value is required"
            }
            if filterOperator.requiresSecondValue && (secondValue?.isEmpty ?? true) {
                return "Second value is required for BETWEEN"
            }
        }

        return nil
    }
}

/// Stores per-tab filter state (preserves filters when switching tabs)
struct TabFilterState: Equatable, Codable {
    var filters: [TableFilter]
    var appliedFilters: [TableFilter]
    var isVisible: Bool

    init() {
        self.filters = []
        self.appliedFilters = []
        self.isVisible = false
    }

    var hasChanges: Bool {
        !filters.isEmpty || !appliedFilters.isEmpty
    }

    var hasAppliedFilters: Bool {
        !appliedFilters.isEmpty
    }
}
