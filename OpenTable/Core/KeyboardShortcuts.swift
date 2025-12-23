//
//  KeyboardShortcuts.swift
//  OpenTable
//
//  Centralized keyboard shortcut definitions following macOS Human Interface Guidelines.
//  Reference: https://developer.apple.com/design/human-interface-guidelines/keyboards
//
//  This file serves as the single source of truth for all keyboard shortcuts in the app.
//  When adding new shortcuts, check this file first to avoid conflicts.
//

import SwiftUI

// MARK: - Keyboard Shortcut Definitions

/// Centralized keyboard shortcut definitions following macOS conventions.
///
/// ## macOS Standard Shortcuts (System-defined, should not be overridden):
/// - ⌘Q: Quit application
/// - ⌘H: Hide application
/// - ⌘,: Open Settings/Preferences
/// - ⌘M: Minimize window
/// - ⌘W: Close window/tab
/// - ⌘N: New document/connection
/// - ⌘O: Open document
/// - ⌘S: Save
/// - ⌘Z: Undo
/// - ⌘⇧Z: Redo
/// - ⌘X: Cut
/// - ⌘C: Copy
/// - ⌘V: Paste
/// - ⌘A: Select All
/// - ⌘F: Find
///
/// ## Application-Specific Shortcuts:
/// These follow macOS conventions where similar functionality exists.
enum KeyboardShortcuts {
    
    // MARK: - File Menu
    
    /// New Connection (⌘N)
    /// Standard macOS shortcut for creating new items
    static let newConnection = KeyboardShortcut("n", modifiers: .command)
    
    /// New Tab (⌘T)
    /// Standard macOS shortcut for new tabs (Safari, Terminal, etc.)
    static let newTab = KeyboardShortcut("t", modifiers: .command)
    
    /// Close Tab (⌘W)
    /// Standard macOS shortcut for closing current tab/window
    static let closeTab = KeyboardShortcut("w", modifiers: .command)
    
    /// Save Changes (⌘S)
    /// Standard macOS shortcut for saving
    static let saveChanges = KeyboardShortcut("s", modifiers: .command)
    
    /// Refresh (⌘R)
    /// Standard shortcut for refresh (Safari, Finder, etc.)
    static let refresh = KeyboardShortcut("r", modifiers: .command)
    
    // MARK: - Edit Menu
    
    /// Undo (⌘Z)
    /// Standard macOS undo shortcut
    static let undo = KeyboardShortcut("z", modifiers: .command)
    
    /// Redo (⌘⇧Z)
    /// Standard macOS redo shortcut
    static let redo = KeyboardShortcut("z", modifiers: [.command, .shift])
    
    /// Cut (⌘X)
    /// Standard macOS cut shortcut
    static let cut = KeyboardShortcut("x", modifiers: .command)
    
    /// Copy (⌘C)
    /// Standard macOS copy shortcut
    static let copy = KeyboardShortcut("c", modifiers: .command)
    
    /// Paste (⌘V)
    /// Standard macOS paste shortcut
    static let paste = KeyboardShortcut("v", modifiers: .command)
    
    /// Select All (⌘A)
    /// Standard macOS select all shortcut
    static let selectAll = KeyboardShortcut("a", modifiers: .command)
    
    /// Delete (⌘⌫)
    /// Delete selected items - macOS uses Cmd+Delete for moving to Trash
    static let delete = KeyboardShortcut(.delete, modifiers: .command)
    
    /// Clear Selection (Escape)
    /// Standard macOS convention for canceling/clearing
    static let clearSelection = KeyboardShortcut(.escape, modifiers: [])
    
    // MARK: - Row Operations (Edit Menu - Custom)
    
    /// Add Row (⌘I)
    /// Insert new row - 'I' for Insert, follows database convention
    static let addRow = KeyboardShortcut("i", modifiers: .command)
    
    /// Duplicate Row (⌘D)
    /// Duplicate selected item - follows Finder/Keynote convention
    static let duplicateRow = KeyboardShortcut("d", modifiers: .command)
    
    /// Truncate Table (⌥⌫)
    /// Dangerous operation, uses Option modifier for extra confirmation
    static let truncateTable = KeyboardShortcut(.delete, modifiers: .option)
    
    // MARK: - View Menu
    
    /// Toggle Table Browser/Sidebar (⌘B)
    /// Similar to Safari's bookmarks sidebar toggle
    static let toggleSidebar = KeyboardShortcut("b", modifiers: .command)
    
    /// Toggle Inspector (⌘⌥B)
    /// Similar to Xcode's inspector toggle
    static let toggleInspector = KeyboardShortcut("b", modifiers: [.command, .option])
    
    /// Toggle Filters (⌘F)
    /// Standard find/filter shortcut
    static let toggleFilters = KeyboardShortcut("f", modifiers: .command)
    
    /// Toggle History Panel (⌘⇧H)
    /// History panel toggle - H for History
    static let toggleHistory = KeyboardShortcut("h", modifiers: [.command, .shift])
    
    // MARK: - Query Editor
    
    /// Execute Query (⌘↩)
    /// Standard shortcut for executing/running in many IDEs
    static let executeQuery = KeyboardShortcut(.return, modifiers: .command)
    
    /// Format Query (⌘⇧L)
    /// Format/beautify the SQL query
    static let formatQuery = KeyboardShortcut("l", modifiers: [.command, .shift])
    
    /// Trigger Autocomplete (⌃Space)
    /// Standard IDE autocomplete trigger
    static let triggerAutocomplete = KeyboardShortcut(.space, modifiers: .control)
    
    // MARK: - Navigation
    
    /// Next Tab (⌘⇧])
    /// Standard macOS tab navigation (Safari, Terminal)
    static let nextTab = KeyboardShortcut("]", modifiers: [.command, .shift])
    
    /// Previous Tab (⌘⇧[)
    /// Standard macOS tab navigation (Safari, Terminal)
    static let previousTab = KeyboardShortcut("[", modifiers: [.command, .shift])
    
    // MARK: - Window
    
    /// Minimize (⌘M)
    /// Standard macOS minimize - handled by system
    static let minimize = KeyboardShortcut("m", modifiers: .command)
    
    /// Zoom/Full Screen (⌃⌘F)
    /// Standard macOS full screen toggle
    static let fullScreen = KeyboardShortcut("f", modifiers: [.control, .command])
}

// MARK: - Shortcut Documentation

/// Documentation of all keyboard shortcuts for reference.
/// This can be displayed in a help menu or settings panel.
struct ShortcutDocumentation {
    
    struct ShortcutInfo {
        let keys: String
        let description: String
        let category: String
    }
    
    static let allShortcuts: [ShortcutInfo] = [
        // File
        ShortcutInfo(keys: "⌘N", description: "New Connection", category: "File"),
        ShortcutInfo(keys: "⌘T", description: "New Tab", category: "File"),
        ShortcutInfo(keys: "⌘W", description: "Close Tab", category: "File"),
        ShortcutInfo(keys: "⌘S", description: "Save Changes", category: "File"),
        ShortcutInfo(keys: "⌘R", description: "Refresh", category: "File"),
        
        // Edit
        ShortcutInfo(keys: "⌘Z", description: "Undo", category: "Edit"),
        ShortcutInfo(keys: "⌘⇧Z", description: "Redo", category: "Edit"),
        ShortcutInfo(keys: "⌘X", description: "Cut", category: "Edit"),
        ShortcutInfo(keys: "⌘C", description: "Copy", category: "Edit"),
        ShortcutInfo(keys: "⌘V", description: "Paste", category: "Edit"),
        ShortcutInfo(keys: "⌘A", description: "Select All", category: "Edit"),
        ShortcutInfo(keys: "⌘⌫", description: "Delete", category: "Edit"),
        ShortcutInfo(keys: "⌘I", description: "Add Row", category: "Edit"),
        ShortcutInfo(keys: "⌘D", description: "Duplicate Row", category: "Edit"),
        ShortcutInfo(keys: "⌥⌫", description: "Truncate Table", category: "Edit"),
        ShortcutInfo(keys: "Escape", description: "Clear Selection", category: "Edit"),
        
        // View
        ShortcutInfo(keys: "⌘B", description: "Toggle Table Browser", category: "View"),
        ShortcutInfo(keys: "⌘⌥B", description: "Toggle Inspector", category: "View"),
        ShortcutInfo(keys: "⌘F", description: "Toggle Filters", category: "View"),
        ShortcutInfo(keys: "⌘⇧H", description: "Toggle History", category: "View"),
        
        // Query
        ShortcutInfo(keys: "⌘↩", description: "Execute Query", category: "Query"),
        ShortcutInfo(keys: "⌘⇧L", description: "Format Query", category: "Query"),
        ShortcutInfo(keys: "⌃Space", description: "Trigger Autocomplete", category: "Query"),
        
        // Navigation
        ShortcutInfo(keys: "⌘⇧]", description: "Next Tab", category: "Navigation"),
        ShortcutInfo(keys: "⌘⇧[", description: "Previous Tab", category: "Navigation"),
        
        // Data Grid
        ShortcutInfo(keys: "↩", description: "Edit Cell", category: "Data Grid"),
        ShortcutInfo(keys: "Tab", description: "Next Cell", category: "Data Grid"),
        ShortcutInfo(keys: "⇧Tab", description: "Previous Cell", category: "Data Grid"),
        ShortcutInfo(keys: "↑↓←→", description: "Navigate Cells", category: "Data Grid"),
        ShortcutInfo(keys: "⇧↑↓", description: "Extend Selection", category: "Data Grid"),
    ]
}

// MARK: - Key Code Constants

/// AppKit key codes for use in NSEvent handling.
/// These are used in performKeyEquivalent and keyDown handlers.
enum KeyCodes {
    // Letters
    static let a: UInt16 = 0
    static let b: UInt16 = 11
    static let c: UInt16 = 8
    static let d: UInt16 = 2
    static let e: UInt16 = 14
    static let f: UInt16 = 3
    static let g: UInt16 = 5
    static let h: UInt16 = 4
    static let i: UInt16 = 34
    static let j: UInt16 = 38
    static let k: UInt16 = 40
    static let l: UInt16 = 37
    static let m: UInt16 = 46
    static let n: UInt16 = 45
    static let o: UInt16 = 31
    static let p: UInt16 = 35
    static let q: UInt16 = 12
    static let r: UInt16 = 15
    static let s: UInt16 = 1
    static let t: UInt16 = 17
    static let u: UInt16 = 32
    static let v: UInt16 = 9
    static let w: UInt16 = 13
    static let x: UInt16 = 7
    static let y: UInt16 = 16
    static let z: UInt16 = 6
    
    // Numbers
    static let zero: UInt16 = 29
    static let one: UInt16 = 18
    static let two: UInt16 = 19
    static let three: UInt16 = 20
    static let four: UInt16 = 21
    static let five: UInt16 = 23
    static let six: UInt16 = 22
    static let seven: UInt16 = 26
    static let eight: UInt16 = 28
    static let nine: UInt16 = 25
    
    // Special Keys
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51  // Backspace
    static let escape: UInt16 = 53
    static let forwardDelete: UInt16 = 117
    
    // Arrow Keys
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    
    // Function Keys
    static let f1: UInt16 = 122
    static let f2: UInt16 = 120
    static let f3: UInt16 = 99
    static let f4: UInt16 = 118
    static let f5: UInt16 = 96
    static let f6: UInt16 = 97
    static let f7: UInt16 = 98
    static let f8: UInt16 = 100
    static let f9: UInt16 = 101
    static let f10: UInt16 = 109
    static let f11: UInt16 = 103
    static let f12: UInt16 = 111
    
    // Brackets
    static let leftBracket: UInt16 = 33   // [
    static let rightBracket: UInt16 = 30  // ]
    
    // Keypad Enter (different from Return)
    static let keypadEnter: UInt16 = 76
}
