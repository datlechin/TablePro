//
//  HistoryTableView.swift
//  TablePro
//
//  Custom NSTableView with keyboard handling for history panel.
//  Extracted from HistoryListViewController for better maintainability.
//

import AppKit

/// Protocol for keyboard event delegation
protocol HistoryTableViewKeyboardDelegate: AnyObject {
    func handleDeleteKey()
    func handleReturnKey()
    func handleSpaceKey()
    func handleEditBookmark()
    func handleEscapeKey()
    func deleteSelectedRow()
    func copy(_ sender: Any?)
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool
}

/// Custom table view for keyboard delegation in history panel
final class HistoryTableView: NSTableView, NSMenuItemValidation {
    weak var keyboardDelegate: HistoryTableViewKeyboardDelegate?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Ensure we become first responder for keyboard shortcuts
        window?.makeFirstResponder(self)
    }

    // MARK: - Standard Responder Actions

    @objc func delete(_ sender: Any?) {
        keyboardDelegate?.deleteSelectedRow()
    }

    @objc func copy(_ sender: Any?) {
        keyboardDelegate?.copy(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(delete(_:)) {
            return keyboardDelegate?.validateMenuItem(menuItem) ?? false
        }
        if menuItem.action == #selector(copy(_:)) {
            return selectedRow >= 0
        }
        return false
    }

    // MARK: - Keyboard Event Handling

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Return/Enter key - open in new tab
        if (event.keyCode == 36 || event.keyCode == 76) && modifiers.isEmpty {
            if selectedRow >= 0 {
                keyboardDelegate?.handleReturnKey()
                return
            }
        }

        // Space key - toggle preview
        if event.keyCode == 49 && modifiers.isEmpty {
            if selectedRow >= 0 {
                keyboardDelegate?.handleSpaceKey()
                return
            }
        }

        // Cmd+E - edit bookmark
        if event.keyCode == 14 && modifiers == .command {
            keyboardDelegate?.handleEditBookmark()
            return
        }

        // Escape key - clear search or selection
        if event.keyCode == 53 && modifiers.isEmpty {
            keyboardDelegate?.handleEscapeKey()
            return
        }

        // Delete key (bare, not Cmd+Delete which goes through menu)
        if event.keyCode == 51 && modifiers.isEmpty {
            if selectedRow >= 0 {
                keyboardDelegate?.handleDeleteKey()
                return
            }
        }

        super.keyDown(with: event)
    }
}
