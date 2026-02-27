//
//  VimCommandLineHandler.swift
//  TablePro
//
//  Handles Vim command-line commands (:w, :q, etc.)
//

import Foundation

/// Handles Vim command-line commands
struct VimCommandLineHandler {
    /// Callback to execute the current query (:w)
    var onExecuteQuery: (() -> Void)?

    /// Callback to close the current tab (:q)
    var onCloseTab: (() -> Void)?

    /// Process a command string (without the leading : or /)
    func handle(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)

        switch trimmed {
        case "w":
            onExecuteQuery?()
        case "q":
            onCloseTab?()
        case "wq":
            onExecuteQuery?()
            onCloseTab?()
        default:
            break // Unknown commands are silently ignored
        }
    }
}
