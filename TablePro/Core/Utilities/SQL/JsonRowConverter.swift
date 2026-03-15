//
//  JsonRowConverter.swift
//  TablePro
//

import Foundation

struct JsonRowConverter {
    let columns: [String]
    let columnTypes: [ColumnType]

    private static let maxRows = 50_000

    func generateJson(rows: [[String?]]) -> String {
        let cappedRows = rows.prefix(Self.maxRows)
        let rowCount = cappedRows.count

        if rowCount == 0 {
            return "[]"
        }

        // Estimate capacity: ~100 bytes per cell as rough heuristic
        var result = String()
        result.reserveCapacity(rowCount * columns.count * 100)

        result.append("[\n")

        for (rowIdx, row) in cappedRows.enumerated() {
            result.append("  {\n")

            for (colIdx, column) in columns.enumerated() {
                result.append("    \"")
                result.append(escapeString(column))
                result.append("\": ")

                guard row.indices.contains(colIdx), let value = row[colIdx] else {
                    result.append("null")
                    appendPropertySuffix(to: &result, colIdx: colIdx)
                    continue
                }

                let colType: ColumnType
                if columnTypes.indices.contains(colIdx) {
                    colType = columnTypes[colIdx]
                } else {
                    colType = .text(rawType: nil)
                }

                result.append(formatValue(value, type: colType))
                appendPropertySuffix(to: &result, colIdx: colIdx)
            }

            result.append("  }")
            if rowIdx < rowCount - 1 {
                result.append(",")
            }
            result.append("\n")
        }

        result.append("]")
        return result
    }

    private func appendPropertySuffix(to result: inout String, colIdx: Int) {
        if colIdx < columns.count - 1 {
            result.append(",")
        }
        result.append("\n")
    }

    private func formatValue(_ value: String, type: ColumnType) -> String {
        switch type {
        case .integer:
            return formatInteger(value)
        case .decimal:
            return formatDecimal(value)
        case .boolean:
            return formatBoolean(value)
        case .json:
            return formatJson(value)
        case .blob:
            return formatBlob(value)
        case .text, .date, .timestamp, .datetime, .enumType, .set, .spatial:
            return quotedEscaped(value)
        }
    }

    private func formatInteger(_ value: String) -> String {
        if let intVal = Int64(value) {
            return String(intVal)
        }
        if let doubleVal = Double(value), doubleVal == doubleVal.rounded(.towardZero), !doubleVal.isInfinite, !doubleVal.isNaN {
            return String(Int64(doubleVal))
        }
        return quotedEscaped(value)
    }

    private func formatDecimal(_ value: String) -> String {
        if let doubleVal = Double(value), !doubleVal.isInfinite, !doubleVal.isNaN {
            return String(format: "%g", doubleVal)
        }
        return quotedEscaped(value)
    }

    private func formatBoolean(_ value: String) -> String {
        switch value.lowercased() {
        case "true", "1", "yes", "on":
            return "true"
        case "false", "0", "no", "off":
            return "false"
        default:
            return quotedEscaped(value)
        }
    }

    private func formatJson(_ value: String) -> String {
        guard let data = value.data(using: .utf8) else {
            return quotedEscaped(value)
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            return value
        } catch {
            return quotedEscaped(value)
        }
    }

    private func formatBlob(_ value: String) -> String {
        guard let data = value.data(using: .utf8) else {
            return quotedEscaped(value)
        }
        let encoded = data.base64EncodedString()
        return "\"\(encoded)\""
    }

    private func quotedEscaped(_ value: String) -> String {
        "\"\(escapeString(value))\""
    }

    private func escapeString(_ value: String) -> String {
        var result = String()
        result.reserveCapacity((value as NSString).length)

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                result.append("\\\"")
            case "\\":
                result.append("\\\\")
            case "\n":
                result.append("\\n")
            case "\r":
                result.append("\\r")
            case "\t":
                result.append("\\t")
            default:
                if scalar.value < 0x20 {
                    result.append(String(format: "\\u%04X", scalar.value))
                } else {
                    result.append(Character(scalar))
                }
            }
        }

        return result
    }
}
