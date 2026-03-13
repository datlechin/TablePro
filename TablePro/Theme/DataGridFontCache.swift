//
//  DataGridFontCache.swift
//  TablePro
//
//  Cached font variants for the data grid.
//  Updated via reloadFromSettings() when user changes font preferences.
//

import AppKit

struct DataGridFontCache {
    private(set) static var regular = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private(set) static var italic = regular.withTraits(.italic)
    private(set) static var medium = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    private(set) static var rowNumber = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private(set) static var measureFont = regular
    private(set) static var monoCharWidth: CGFloat = {
        let attrs: [NSAttributedString.Key: Any] = [.font: regular]
        return ("M" as NSString).size(withAttributes: attrs).width
    }()

    @MainActor
    static func reloadFromSettings(_ settings: DataGridSettings) {
        let scale = SQLEditorTheme.accessibilityScaleFactor
        let scaledSize = round(CGFloat(settings.clampedFontSize) * scale)
        regular = settings.fontFamily.font(size: scaledSize)
        italic = regular.withTraits(.italic)
        medium = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        let rowNumSize = max(round(scaledSize - 1), 9)
        rowNumber = NSFont.monospacedDigitSystemFont(ofSize: rowNumSize, weight: .regular)
        measureFont = regular
        let attrs: [NSAttributedString.Key: Any] = [.font: regular]
        monoCharWidth = ("M" as NSString).size(withAttributes: attrs).width
    }
}
