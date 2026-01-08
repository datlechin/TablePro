//
//  SQLCompletionWindowController.swift
//  TablePro
//
//  Popup window for SQL autocomplete suggestions
//

import AppKit
import SwiftUI

// MARK: - Completion Window Controller

/// Controller for the autocomplete popup window
final class SQLCompletionWindowController: NSObject {
    // MARK: - Properties

    private var window: NSPanel?
    private var tableView: NSTableView?
    private var scrollView: NSScrollView?
    private var mouseEventMonitor: Any?

    private var items: [SQLCompletionItem] = []
    private var selectedIndex: Int = 0

    /// Callback when an item is selected
    var onSelect: ((SQLCompletionItem) -> Void)?

    /// Callback when completion is dismissed
    var onDismiss: (() -> Void)?

    /// Whether the window is currently visible
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - Window Configuration

    private let windowWidth: CGFloat = 400
    private let rowHeight: CGFloat = DesignConstants.RowHeight.compact
    private let maxVisibleRows: Int = 10

    // MARK: - Lifecycle

    deinit {
        removeMouseMonitor()
        if let panel = window {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    // MARK: - Public API

    /// Show completions at the specified screen position
    func showCompletions(
        _ items: [SQLCompletionItem],
        at position: NSPoint,
        relativeTo parentWindow: NSWindow?
    ) {
        guard !items.isEmpty else {
            dismiss()
            return
        }

        self.items = items
        self.selectedIndex = 0

        // CRITICAL: Dismiss existing window first to prevent duplicates
        // This ensures only one window exists at a time
        if window?.isVisible == true {
            window?.parent?.removeChildWindow(window!)
            window?.orderOut(nil)
        }

        // Create or update window
        if window == nil {
            createWindow()
        }

        let height = calculateWindowHeight(for: items.count)

        // Position window
        var windowOrigin = position
        windowOrigin.y -= height  // Position below cursor

        // Ensure window stays on screen
        if let screen = parentWindow?.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame

            if windowOrigin.x + windowWidth > screenFrame.maxX {
                windowOrigin.x = screenFrame.maxX - windowWidth - 10
            }
            if windowOrigin.y < screenFrame.minY {
                windowOrigin.y = position.y + 20  // Position above cursor instead
            }
        }

        let frameRect = NSRect(x: windowOrigin.x, y: windowOrigin.y, width: windowWidth, height: height)
        let selectedIdx = self.selectedIndex
        let panel = self.window

        // Ensure all UI updates run on the main thread
        let uiUpdates = { [weak self] in
            guard let self = self else { return }
            self.tableView?.reloadData()
            self.tableView?.selectRowIndexes(IndexSet(integer: selectedIdx), byExtendingSelection: false)
            panel?.setFrame(frameRect, display: true)

            // Show window
            if let parent = parentWindow, let panel = panel {
                parent.addChildWindow(panel, ordered: .above)
            }
            panel?.orderFront(nil)

            // Install mouse monitor for click-outside detection
            self.installMouseMonitor()
        }

        if Thread.isMainThread {
            uiUpdates()
        } else {
            DispatchQueue.main.async(execute: uiUpdates)
        }
    }

    /// Update completions without repositioning
    func updateCompletions(_ items: [SQLCompletionItem]) {
        guard !items.isEmpty else {
            dismiss()
            return
        }

        self.items = items
        self.selectedIndex = min(selectedIndex, items.count - 1)

        let height = calculateWindowHeight(for: items.count)
        let selectedIdx = self.selectedIndex

        var newFrame: NSRect?
        if var frame = window?.frame {
            let oldY = frame.origin.y + frame.height
            frame.size.height = height
            frame.origin.y = oldY - height
            newFrame = frame
        }

        // Ensure all UI updates run on the main thread
        let uiUpdates = { [weak self] in
            guard let self = self else { return }
            self.tableView?.reloadData()
            self.tableView?.selectRowIndexes(IndexSet(integer: selectedIdx), byExtendingSelection: false)
            if let frame = newFrame {
                self.window?.setFrame(frame, display: true)
            }
        }

        if Thread.isMainThread {
            uiUpdates()
        } else {
            DispatchQueue.main.async(execute: uiUpdates)
        }
    }

    /// Dismiss the completion window
    func dismiss() {
        guard let panel = window else {
            onDismiss?()
            return
        }

        let dismissAction = { [weak self] in
            self?.removeMouseMonitor()
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self?.onDismiss?()
        }

        if Thread.isMainThread {
            dismissAction()
        } else {
            DispatchQueue.main.async(execute: dismissAction)
        }
    }

    // MARK: - Mouse Event Monitoring

    private func installMouseMonitor() {
        removeMouseMonitor()

        mouseEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self, let window = self.window else { return }

            // Get click location in screen coordinates
            let clickLocation = event.locationInWindow
            let clickScreenX = clickLocation.x + (event.window?.frame.origin.x ?? 0)
            let clickScreenY = clickLocation.y + (event.window?.frame.origin.y ?? 0)
            let clickScreen = NSPoint(x: clickScreenX, y: clickScreenY)

            // If click is outside completion window, dismiss
            if !window.frame.contains(clickScreen) {
                self.dismiss()
            }
        }
    }

    private func removeMouseMonitor() {
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
    }

    // MARK: - Keyboard Navigation

    /// Handle key event, returns true if handled
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }

        switch event.keyCode {
        case 125: // Down arrow
            selectNext()
            return true

        case 126: // Up arrow
            selectPrevious()
            return true

        case 36: // Return
            confirmSelection()
            return true

        case 53: // Escape
            dismiss()
            return true

        case 48: // Tab
            confirmSelection()
            return true

        default:
            return false
        }
    }

    /// Move selection down
    func selectNext() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
        let idx = selectedIndex
        performOnMainThread { [weak self] in
            self?.tableView?.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            self?.tableView?.scrollRowToVisible(idx)
        }
    }

    /// Move selection up
    func selectPrevious() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        let idx = selectedIndex
        performOnMainThread { [weak self] in
            self?.tableView?.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            self?.tableView?.scrollRowToVisible(idx)
        }
    }

    /// Confirm current selection
    func confirmSelection() {
        guard selectedIndex < items.count else { return }
        let item = items[selectedIndex]
        dismiss()
        onSelect?(item)
    }

    // MARK: - Private Helpers

    /// Calculate window height based on item count
    private func calculateWindowHeight(for itemCount: Int) -> CGFloat {
        let visibleRows = min(itemCount, maxVisibleRows)
        return CGFloat(visibleRows) * rowHeight + 4
    }

    /// Execute a closure on the main thread
    private func performOnMainThread(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    // MARK: - Window Creation

    private func createWindow() {
        // Create panel (non-activating)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = NSColor.controlBackgroundColor
        panel.isOpaque = false

        // Create scroll view
        let scrollBounds = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: windowWidth, height: 200)
        let scroll = NSScrollView(frame: scrollBounds)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.controlBackgroundColor

        // Create table view
        let table = NSTableView()
        table.style = .plain
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = NSColor.controlBackgroundColor
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .regular
        table.delegate = self
        table.dataSource = self
        table.doubleAction = #selector(tableDoubleClicked)
        table.target = self

        // Add single column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.width = windowWidth - 20
        table.addTableColumn(column)

        scroll.documentView = table
        panel.contentView = scroll

        // Add visual polish: rounded corners, border
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 8
        panel.contentView?.layer?.masksToBounds = true
        panel.contentView?.layer?.borderWidth = 1
        panel.contentView?.layer?.borderColor = NSColor.separatorColor.cgColor

        self.window = panel
        self.tableView = table
        self.scrollView = scroll
    }

    @objc private func tableDoubleClicked() {
        confirmSelection()
    }
}

// MARK: - NSTableViewDelegate & DataSource

extension SQLCompletionWindowController: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        // Reuse or create cell view
        let cellId = NSUserInterfaceItemIdentifier("CompletionCell")
        var cellView = tableView.makeView(withIdentifier: cellId, owner: nil) as? CompletionCellView

        if cellView == nil {
            cellView = CompletionCellView()
            cellView?.identifier = cellId
        }

        cellView?.configure(with: item)
        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let table = notification.object as? NSTableView, table.selectedRow >= 0 {
            selectedIndex = table.selectedRow
        }
        // Do not reset selectedIndex when selectedRow == -1 to prevent accidental selection jumps
    }
}

// MARK: - Completion Cell View

private final class CompletionCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let kindBadge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        // Icon with background
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 3
        addSubview(iconView)

        // Label (main text)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(labelField)

        // Kind badge (small label like "func", "col", "tbl")
        kindBadge.translatesAutoresizingMaskIntoConstraints = false
        kindBadge.font = .systemFont(ofSize: 9, weight: .medium)
        kindBadge.textColor = .white
        kindBadge.alignment = .center
        kindBadge.wantsLayer = true
        kindBadge.layer?.cornerRadius = 3
        kindBadge.layer?.masksToBounds = true
        kindBadge.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(kindBadge)

        // Detail (type info)
        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = .systemFont(ofSize: 10)
        detailField.textColor = .tertiaryLabelColor
        detailField.alignment = .right
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(detailField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            labelField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),

            kindBadge.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: 6),
            kindBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            kindBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            kindBadge.heightAnchor.constraint(equalToConstant: 14),

            detailField.leadingAnchor.constraint(greaterThanOrEqualTo: kindBadge.trailingAnchor, constant: 6),
            detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detailField.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.widthAnchor.constraint(lessThanOrEqualToConstant: 100),
        ])
    }

    func configure(with item: SQLCompletionItem) {
        // Icon
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: item.kind.iconName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            iconView.image = image
            iconView.contentTintColor = item.kind.iconColor
        }

        // Label
        labelField.stringValue = item.label

        // Kind badge
        kindBadge.stringValue = kindAbbreviation(for: item.kind)
        kindBadge.layer?.backgroundColor = item.kind.iconColor.withAlphaComponent(0.8).cgColor

        // Detail (show type for columns, signature for functions)
        detailField.stringValue = item.detail ?? ""

        // Tooltip with full documentation
        if let doc = item.documentation, !doc.isEmpty {
            self.toolTip = doc
        } else if let detail = item.detail {
            self.toolTip = "\(item.label): \(detail)"
        } else {
            self.toolTip = item.label
        }
    }

    /// Get short abbreviation for kind badge
    private func kindAbbreviation(for kind: SQLCompletionKind) -> String {
        switch kind {
        case .keyword: return "key"
        case .table: return "tbl"
        case .view: return "view"
        case .column: return "col"
        case .function: return "fn"
        case .schema: return "db"
        case .alias: return "as"
        case .operator: return "op"
        }
    }
}
