//
//  VimRegister.swift
//  TablePro
//
//  Vim register for storing yanked/deleted text
//

import AppKit

/// Vim register for yank/delete/paste operations
struct VimRegister {
    /// The stored text content
    var text: String = "" {
        didSet {
            if !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    /// Whether the text was yanked/deleted linewise (entire lines)
    var isLinewise: Bool = false
}
