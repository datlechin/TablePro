//
//  JSONExportModels.swift
//  JSONExportPlugin
//

import Foundation

public struct JSONExportOptions: Equatable {
    public var prettyPrint: Bool = true
    public var includeNullValues: Bool = true
    public var preserveAllAsStrings: Bool = false

    public init() {}
}
