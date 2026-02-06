//
//  DataGridCellFactory.swift
//  OpenTable
//
//  Factory for creating and configuring data grid cells.
//  Extracted from DataGridView coordinator for better maintainability.
//

import AppKit
import QuartzCore

/// Factory for creating data grid cell views
final class DataGridCellFactory {
    private let cellIdentifier = NSUserInterfaceItemIdentifier("DataCell")
    private let rowNumberCellIdentifier = NSUserInterfaceItemIdentifier("RowNumberCell")

    /// Large dataset threshold - above this, disable expensive visual features
    private let largeDatasetThreshold = 5_000

    /// Maximum characters to render in a cell (for performance with very large text)
    private let maxCellTextLength = 10_000

    // MARK: - Cached Fonts (avoid recreation per cell render)

    private enum CellFonts {
        static let regular = NSFont.monospacedSystemFont(
            ofSize: DesignConstants.FontSize.body,
            weight: .regular
        )
        static let italic = regular.withTraits(.italic)
        static let medium = NSFont.monospacedSystemFont(
            ofSize: DesignConstants.FontSize.body,
            weight: .medium
        )
        static let rowNumber = NSFont.monospacedDigitSystemFont(
            ofSize: DesignConstants.FontSize.medium,
            weight: .regular
        )
    }

    // MARK: - Cached Colors (avoid allocation per cell render)

    private enum CellColors {
        static let deletedBackground = NSColor.systemRed.withAlphaComponent(0.15).cgColor
        static let insertedBackground = NSColor.systemGreen.withAlphaComponent(0.15).cgColor
        static let modifiedBackground = NSColor.systemYellow.withAlphaComponent(0.3).cgColor
        static let deletedText = NSColor.systemRed.withAlphaComponent(0.5)
        static let focusBorder = NSColor.selectedControlColor.cgColor
    }

    // MARK: - Row Number Cell

    func makeRowNumberCell(
        tableView: NSTableView,
        row: Int,
        cachedRowCount: Int,
        visualState: RowVisualState
    ) -> NSView {
        let cellViewId = NSUserInterfaceItemIdentifier("RowNumberCellView")
        let cellView: NSTableCellView
        let cell: NSTextField

        if let reused = tableView.makeView(withIdentifier: cellViewId, owner: nil) as? NSTableCellView,
           let textField = reused.textField {
            cellView = reused
            cell = textField
        } else {
            cellView = NSTableCellView()
            cellView.identifier = cellViewId

            cell = NSTextField(labelWithString: "")
            cell.alignment = .right
            cell.font = CellFonts.rowNumber
            cell.textColor = .secondaryLabelColor
            cell.translatesAutoresizingMaskIntoConstraints = false

            cellView.textField = cell
            cellView.addSubview(cell)

            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                cell.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                cell.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        guard row >= 0 && row < cachedRowCount else {
            cell.stringValue = ""
            return cellView
        }

        cell.stringValue = "\(row + 1)"
        cell.textColor = visualState.isDeleted ? CellColors.deletedText : .secondaryLabelColor

        return cellView
    }

    // MARK: - Data Cell

    func makeDataCell(
        tableView: NSTableView,
        row: Int,
        columnIndex: Int,
        value: String?,
        columnType: ColumnType?,
        visualState: RowVisualState,
        isEditable: Bool,
        isLargeDataset: Bool,
        isFocused: Bool,
        delegate: NSTextFieldDelegate
    ) -> NSView {
        let cellViewId = NSUserInterfaceItemIdentifier("DataCellView")
        let cellView: NSTableCellView
        let cell: NSTextField
        let isNewCell: Bool

        if let reused = tableView.makeView(withIdentifier: cellViewId, owner: nil) as? NSTableCellView,
           let textField = reused.textField {
            cellView = reused
            cell = textField
            isNewCell = false
            // Ensure layer exists for background color
            if !cellView.wantsLayer {
                cellView.wantsLayer = true
            }
        } else {
            cellView = NSTableCellView()
            cellView.identifier = cellViewId
            cellView.wantsLayer = true

            cell = CellTextField()
            cell.font = CellFonts.regular
            cell.drawsBackground = false
            cell.isBordered = false
            cell.focusRingType = .none
            cell.lineBreakMode = .byTruncatingTail
            cell.maximumNumberOfLines = 1
            cell.cell?.truncatesLastVisibleLine = true
            cell.translatesAutoresizingMaskIntoConstraints = false

            cellView.textField = cell
            cellView.addSubview(cell)

            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                cell.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                cell.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
            isNewCell = true
        }

        cell.isEditable = isEditable
        cell.delegate = delegate
        cell.identifier = cellIdentifier

        let isDeleted = visualState.isDeleted
        let isInserted = visualState.isInserted
        let isModified = visualState.modifiedColumns.contains(columnIndex)

        // Update text content
        cell.placeholderString = nil

        if value == nil {
            cell.stringValue = ""
            if !isLargeDataset {
                // Use settings for NULL display text
                cell.placeholderString = AppSettingsManager.shared.dataGrid.nullDisplay
                cell.textColor = .secondaryLabelColor
                if isNewCell || cell.font?.fontDescriptor.symbolicTraits.contains(.italic) != true {
                    cell.font = CellFonts.italic
                }
            } else {
                cell.textColor = .secondaryLabelColor
            }
        } else if value == "__DEFAULT__" {
            cell.stringValue = ""
            if !isLargeDataset {
                cell.placeholderString = "DEFAULT"
                cell.textColor = .systemBlue
                cell.font = CellFonts.medium
            } else {
                cell.textColor = .systemBlue
            }
        } else if value == "" {
            cell.stringValue = ""
            if !isLargeDataset {
                cell.placeholderString = "Empty"
                cell.textColor = .secondaryLabelColor
                if isNewCell || cell.font?.fontDescriptor.symbolicTraits.contains(.italic) != true {
                    cell.font = CellFonts.italic
                }
            } else {
                cell.textColor = .secondaryLabelColor
            }
        } else {
            // Truncate very large text for performance (only visible chars matter)
            var displayValue = value ?? ""

            // Format dates using DateFormattingService if this is a date column
            if let columnType = columnType, columnType.isDateType, !displayValue.isEmpty {
                if let formattedDate = DateFormattingService.shared.format(dateString: displayValue) {
                    displayValue = formattedDate
                }
                // If formatting fails, fall back to original string
            }

            if displayValue.count > maxCellTextLength {
                let truncateIndex = displayValue.index(displayValue.startIndex, offsetBy: maxCellTextLength)
                displayValue = String(displayValue[..<truncateIndex]) + "..."
            }

            // Sanitize: replace newlines with spaces for single-line display
            displayValue = displayValue.sanitizedForCellDisplay

            cell.stringValue = displayValue
            cell.textColor = .labelColor
            if cell.font?.fontDescriptor.symbolicTraits.contains(.italic) == true ||
                cell.font?.fontDescriptor.symbolicTraits.contains(.bold) == true {
                cell.font = CellFonts.regular
            }
        }

        // Batch layer updates to avoid implicit animations
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Update background color
        if isDeleted {
            cellView.layer?.backgroundColor = CellColors.deletedBackground
        } else if isInserted {
            cellView.layer?.backgroundColor = CellColors.insertedBackground
        } else if isModified {
            cellView.layer?.backgroundColor = CellColors.modifiedBackground
        } else {
            cellView.layer?.backgroundColor = nil
        }

        // Focus ring
        if isLargeDataset {
            cellView.layer?.borderWidth = 0
        } else if isFocused {
            cellView.layer?.borderWidth = 2
            cellView.layer?.borderColor = CellColors.focusBorder
        } else {
            cellView.layer?.borderWidth = 0
        }

        CATransaction.commit()

        return cellView
    }

    // MARK: - Column Width Calculation

    /// Minimum column width
    private static let minColumnWidth: CGFloat = 60
    /// Maximum column width - prevents overly wide columns
    private static let maxColumnWidth: CGFloat = 800
    /// Number of rows to sample for width calculation (for performance)
    private static let sampleRowCount = 100
    /// Font for measuring cell content
    private static let measureFont = NSFont.monospacedSystemFont(ofSize: DesignConstants.FontSize.body, weight: .regular)
    /// Font for measuring header
    private static let headerFont = NSFont.systemFont(ofSize: DesignConstants.FontSize.body, weight: .semibold)

    /// Calculate column width based on header name only (used for initial display)
    func calculateColumnWidth(for columnName: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.headerFont]
        let size = (columnName as NSString).size(withAttributes: attributes)
        let width = size.width + 48 // padding for sort indicator + margins
        return min(max(width, Self.minColumnWidth), Self.maxColumnWidth)
    }

    /// Calculate optimal column width based on header and cell content
    /// - Parameters:
    ///   - columnName: The column header name
    ///   - columnIndex: Index of the column
    ///   - rowProvider: Provider to get sample row data
    /// - Returns: Optimal column width within min/max bounds
    func calculateOptimalColumnWidth(
        for columnName: String,
        columnIndex: Int,
        rowProvider: InMemoryRowProvider
    ) -> CGFloat {
        let headerAttributes: [NSAttributedString.Key: Any] = [.font: Self.headerFont]
        let cellAttributes: [NSAttributedString.Key: Any] = [.font: Self.measureFont]

        // Start with header width
        let headerSize = (columnName as NSString).size(withAttributes: headerAttributes)
        var maxWidth = headerSize.width + 48 // padding for sort indicator + margins

        // Sample cell content to find max width
        let totalRows = rowProvider.totalRowCount
        let step = max(1, totalRows / Self.sampleRowCount)

        for i in stride(from: 0, to: totalRows, by: step) {
            guard let row = rowProvider.row(at: i),
                  let value = row.value(at: columnIndex) else { continue }

            // Use first 100 chars for width measurement (sufficient for column sizing)
            let displayValue = String(value.prefix(100))
            let size = (displayValue as NSString).size(withAttributes: cellAttributes)
            maxWidth = max(maxWidth, size.width + 16) // cell padding

            // Early exit if already at max
            if maxWidth >= Self.maxColumnWidth {
                return Self.maxColumnWidth
            }
        }

        return min(max(maxWidth, Self.minColumnWidth), Self.maxColumnWidth)
    }
}

// MARK: - NSFont Extension

extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - String Extension for Cell Display

private extension String {
    /// Sanitize string for single-line cell display by replacing newlines with spaces.
    /// Avoids allocation when string contains no newlines (common case).
    var sanitizedForCellDisplay: String {
        // Fast path: if no newlines exist, return self without allocation
        guard contains(where: { $0 == "\n" || $0 == "\r" }) else { return self }

        // Slow path: build new string with newlines replaced
        var result = ""
        result.reserveCapacity(count)
        for char in self {
            result.append(char == "\n" || char == "\r" ? " " : char)
        }
        return result
    }
}
