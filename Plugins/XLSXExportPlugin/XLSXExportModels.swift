//
//  XLSXExportModels.swift
//  XLSXExportPlugin
//

import Foundation

public struct XLSXExportOptions: Equatable {
    public var includeHeaderRow: Bool = true
    public var convertNullToEmpty: Bool = true

    public init() {}
}
