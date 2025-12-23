//
//  HistoryListViewController.swift
//  OpenTable
//
//  Left pane controller for history/bookmark list with search and filtering
//

import AppKit

// MARK: - Delegate Protocol

protocol HistoryListViewControllerDelegate: AnyObject {
    func historyListViewController(_ controller: HistoryListViewController, didSelectHistoryEntry entry: QueryHistoryEntry)
    func historyListViewController(_ controller: HistoryListViewController, didSelectBookmark bookmark: QueryBookmark)
    func historyListViewController(_ controller: HistoryListViewController, didDoubleClickHistoryEntry entry: QueryHistoryEntry)
    func historyListViewController(_ controller: HistoryListViewController, didDoubleClickBookmark bookmark: QueryBookmark)
    func historyListViewControllerDidClearSelection(_ controller: HistoryListViewController)
}

// MARK: - Display Mode

enum HistoryDisplayMode: Int {
    case history = 0
    case bookmarks = 1
}

// MARK: - UI Date Filter (maps to DateFilter from QueryHistoryStorage)

enum UIDateFilter: Int {
    case today = 0
    case week = 1
    case month = 2
    case all = 3

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "This Week"
        case .month: return "This Month"
        case .all: return "All Time"
        }
    }

    /// Convert to storage DateFilter
    var toDateFilter: DateFilter {
        switch self {
        case .today: return .today
        case .week: return .thisWeek
        case .month: return .thisMonth
        case .all: return .all
        }
    }
}

// MARK: - HistoryListViewController

final class HistoryListViewController: NSViewController, NSMenuItemValidation {

    // MARK: - Properties

    weak var delegate: HistoryListViewControllerDelegate?

    private var displayMode: HistoryDisplayMode = .history {
        didSet {
            if oldValue != displayMode {
                updateFilterVisibility()
                loadData()
            }
        }
    }

    private var dateFilter: UIDateFilter = .all {
        didSet {
            if oldValue != dateFilter {
                loadData()
            }
        }
    }

    private var searchText: String = "" {
        didSet {
            scheduleSearch()
        }
    }

    private var historyEntries: [QueryHistoryEntry] = []
    private var bookmarks: [QueryBookmark] = []

    private var searchTask: DispatchWorkItem?
    private let searchDebounceInterval: TimeInterval = 0.15
    
    // Track pending deletion for smart selection
    private var pendingDeletionRow: Int?
    private var pendingDeletionCount: Int?

    // MARK: - UI Components

    private let headerView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var modeSegment: NSSegmentedControl = {
        let segment = NSSegmentedControl(labels: ["History", "Bookmarks"], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        segment.selectedSegment = 0
        segment.translatesAutoresizingMaskIntoConstraints = false
        segment.controlSize = .small
        return segment
    }()

    private lazy var searchField: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = "Search queries..."
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.controlSize = .small
        return field
    }()

    private lazy var filterButton: NSPopUpButton = {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false

        for filter in [UIDateFilter.today, .week, .month, .all] {
            button.addItem(withTitle: filter.title)
        }
        button.selectItem(at: UIDateFilter.all.rawValue)
        button.target = self
        button.action = #selector(filterChanged(_:))
        return button
    }()

    private let scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        return scroll
    }()

    private lazy var tableView: HistoryTableView = {
        let table = HistoryTableView()
        table.style = .plain
        table.headerView = nil
        table.rowHeight = 56
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.delegate = self
        table.dataSource = self
        table.doubleAction = #selector(tableViewDoubleClick(_:))
        table.target = self
        table.keyboardDelegate = self  // Set keyboard delegate

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.width = 300
        table.addTableColumn(column)

        return table
    }()

    private lazy var emptyStateView: NSView = {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 48),
            imageView.heightAnchor.constraint(equalToConstant: 48)
        ])
        imageView.contentTintColor = .tertiaryLabelColor
        self.emptyImageView = imageView

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        self.emptyTitleLabel = titleLabel

        let subtitleLabel = NSTextField(labelWithString: "")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.preferredMaxLayoutWidth = 200
        self.emptySubtitleLabel = subtitleLabel

        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(subtitleLabel)

        container.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }()

    private weak var emptyImageView: NSImageView?
    private weak var emptyTitleLabel: NSTextField?
    private weak var emptySubtitleLabel: NSTextField?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupNotifications()
        restoreState()
        loadData()
    }

    // MARK: - Setup

    private func setupUI() {
        // Header
        view.addSubview(headerView)

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let topRow = NSStackView(views: [modeSegment, filterButton])
        topRow.distribution = .fill
        topRow.spacing = 8

        headerStack.addArrangedSubview(topRow)
        headerStack.addArrangedSubview(searchField)

        headerView.addSubview(headerStack)

        // Divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(divider)

        // Scroll view with table
        scrollView.documentView = tableView
        view.addSubview(scrollView)

        // Empty state (overlays scroll view)
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            // Header
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            headerStack.topAnchor.constraint(equalTo: headerView.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            headerStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),

            // Divider
            divider.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Empty state
            emptyStateView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])

        updateFilterVisibility()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyDidUpdate),
            name: .queryHistoryDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bookmarksDidUpdate),
            name: .queryBookmarksDidUpdate,
            object: nil
        )
    }

    // MARK: - State Persistence

    private func restoreState() {
        let savedMode = UserDefaults.standard.integer(forKey: "HistoryPanel.displayMode")
        let savedFilter = UserDefaults.standard.integer(forKey: "HistoryPanel.dateFilter")

        if let mode = HistoryDisplayMode(rawValue: savedMode) {
            displayMode = mode
            modeSegment.selectedSegment = mode.rawValue
        }

        if let filter = UIDateFilter(rawValue: savedFilter) {
            dateFilter = filter
            filterButton.selectItem(at: filter.rawValue)
        }
    }

    private func saveState() {
        UserDefaults.standard.set(displayMode.rawValue, forKey: "HistoryPanel.displayMode")
        UserDefaults.standard.set(dateFilter.rawValue, forKey: "HistoryPanel.dateFilter")
    }

    // MARK: - Data Loading

    private func loadData() {
        switch displayMode {
        case .history:
            loadHistory()
        case .bookmarks:
            loadBookmarks()
        }
    }

    private func loadHistory() {
        historyEntries = QueryHistoryManager.shared.fetchHistory(
            limit: 500,
            offset: 0,
            connectionId: nil,
            searchText: searchText.isEmpty ? nil : searchText,
            dateFilter: dateFilter.toDateFilter
        )


        tableView.reloadData()
        updateEmptyState()
        
        // Handle pending deletion selection
        if let deletedRow = pendingDeletionRow, let countBefore = pendingDeletionCount {
            selectRowAfterDeletion(deletedRow: deletedRow, countBefore: countBefore)
            pendingDeletionRow = nil
            pendingDeletionCount = nil
        } else if tableView.selectedRow < 0 {
            // Clear preview if no selection
            delegate?.historyListViewControllerDidClearSelection(self)
        }
    }

    private func loadBookmarks() {
        bookmarks = QueryHistoryManager.shared.fetchBookmarks(
            searchText: searchText.isEmpty ? nil : searchText,
            tag: nil
        )


        tableView.reloadData()
        updateEmptyState()
        
        // Handle pending deletion selection
        if let deletedRow = pendingDeletionRow, let countBefore = pendingDeletionCount {
            selectRowAfterDeletion(deletedRow: deletedRow, countBefore: countBefore)
            pendingDeletionRow = nil
            pendingDeletionCount = nil
        } else if tableView.selectedRow < 0 {
            // Clear preview if no selection
            delegate?.historyListViewControllerDidClearSelection(self)
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()

        let task = DispatchWorkItem { [weak self] in
            self?.loadData()
        }
        searchTask = task

        DispatchQueue.main.asyncAfter(deadline: .now() + searchDebounceInterval, execute: task)
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if let mode = HistoryDisplayMode(rawValue: sender.selectedSegment) {
            displayMode = mode
            saveState()
        }
    }

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        if let filter = UIDateFilter(rawValue: sender.indexOfSelectedItem) {
            dateFilter = filter
            saveState()
        }
    }

    @objc private func tableViewDoubleClick(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0 else { return }

        switch displayMode {
        case .history:
            guard row < historyEntries.count else { return }
            delegate?.historyListViewController(self, didDoubleClickHistoryEntry: historyEntries[row])
        case .bookmarks:
            guard row < bookmarks.count else { return }
            delegate?.historyListViewController(self, didDoubleClickBookmark: bookmarks[row])
        }
    }

    @objc private func historyDidUpdate() {
        if displayMode == .history {
            loadData()
        }
    }

    @objc private func bookmarksDidUpdate() {
        if displayMode == .bookmarks {
            loadData()
        }
    }

    // MARK: - UI Updates

    private func updateFilterVisibility() {
        filterButton.isHidden = displayMode == .bookmarks
        searchField.placeholderString = displayMode == .history ? "Search queries..." : "Search bookmarks..."
    }

    private func updateEmptyState() {
        let isEmpty: Bool
        switch displayMode {
        case .history:
            isEmpty = historyEntries.isEmpty
        case .bookmarks:
            isEmpty = bookmarks.isEmpty
        }

        emptyStateView.isHidden = !isEmpty
        scrollView.isHidden = isEmpty

        guard isEmpty else { return }

        let isSearching = !searchText.isEmpty

        if isSearching {
            emptyImageView?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "No results")
            emptyTitleLabel?.stringValue = "No Matching Queries"
            emptySubtitleLabel?.stringValue = "Try adjusting your search terms\nor date filter."
        } else {
            switch displayMode {
            case .history:
                emptyImageView?.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "No history")
                emptyTitleLabel?.stringValue = "No Query History Yet"
                emptySubtitleLabel?.stringValue = "Your executed queries will\nappear here for quick access."
            case .bookmarks:
                emptyImageView?.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "No bookmarks")
                emptyTitleLabel?.stringValue = "No Bookmarks Yet"
                emptySubtitleLabel?.stringValue = "Save frequently used queries\nusing Cmd+Shift+B."
            }
        }
    }

    // MARK: - Context Menu

    private func buildContextMenu(for row: Int) -> NSMenu {
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "Copy Query", action: #selector(copyQuery(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.tag = row
        menu.addItem(copyItem)

        let runItem = NSMenuItem(title: "Run in New Tab", action: #selector(runInNewTab(_:)), keyEquivalent: "\r")
        runItem.tag = row
        menu.addItem(runItem)

        menu.addItem(NSMenuItem.separator())

        switch displayMode {
        case .history:
            let bookmarkItem = NSMenuItem(title: "Save as Bookmark...", action: #selector(saveAsBookmark(_:)), keyEquivalent: "")
            bookmarkItem.tag = row
            menu.addItem(bookmarkItem)
        case .bookmarks:
            let editItem = NSMenuItem(title: "Edit Bookmark...", action: #selector(editBookmark(_:)), keyEquivalent: "e")
            editItem.keyEquivalentModifierMask = .command
            editItem.tag = row
            menu.addItem(editItem)
        }

        menu.addItem(NSMenuItem.separator())

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteEntry(_:)), keyEquivalent: "\u{8}")
        deleteItem.keyEquivalentModifierMask = []
        deleteItem.tag = row
        menu.addItem(deleteItem)

        return menu
    }

    @objc private func copyQuery(_ sender: NSMenuItem) {
        let row = sender.tag
        let query: String

        switch displayMode {
        case .history:
            guard row < historyEntries.count else { return }
            query = historyEntries[row].query
        case .bookmarks:
            guard row < bookmarks.count else { return }
            query = bookmarks[row].query
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(query, forType: .string)
    }

    @objc private func runInNewTab(_ sender: NSMenuItem) {
        let row = sender.tag
        let query: String

        switch displayMode {
        case .history:
            guard row < historyEntries.count else { return }
            query = historyEntries[row].query
        case .bookmarks:
            guard row < bookmarks.count else { return }
            query = bookmarks[row].query
            QueryHistoryManager.shared.markBookmarkUsed(id: bookmarks[row].id)
        }

        NotificationCenter.default.post(name: .newTab, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(
                name: .loadQueryIntoEditor,
                object: nil,
                userInfo: ["query": query]
            )
        }
    }

    @objc private func saveAsBookmark(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row < historyEntries.count else { return }
        let entry = historyEntries[row]

        let editor = BookmarkEditorController(
            bookmark: nil,
            query: entry.query,
            connectionId: entry.connectionId
        )

        editor.onSave = { [weak self] bookmark in
            let success = QueryHistoryManager.shared.saveBookmark(
                name: bookmark.name,
                query: bookmark.query,
                connectionId: bookmark.connectionId,
                tags: bookmark.tags,
                notes: bookmark.notes
            )
            
            if success {
            } else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Save Bookmark"
                    alert.informativeText = "Could not save the bookmark to storage. Please try again."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }

        view.window?.contentViewController?.presentAsSheet(editor)
    }

    @objc private func editBookmark(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row < bookmarks.count else { return }
        let bookmark = bookmarks[row]

        let editorView = BookmarkEditorView(
            bookmark: bookmark,
            query: bookmark.query,
            connectionId: bookmark.connectionId
        ) { [weak self] updatedBookmark in
            let success = QueryHistoryManager.shared.updateBookmark(updatedBookmark)
            
            if success {
            } else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Update Bookmark"
                    alert.informativeText = "Could not save changes to the bookmark. Please try again."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }

        presentAsSheet(editorView)
    }

    @objc private func deleteEntry(_ sender: NSMenuItem) {
        let row = sender.tag

        switch displayMode {
        case .history:
            guard row < historyEntries.count else { return }
            let entry = historyEntries[row]
            QueryHistoryManager.shared.deleteHistory(id: entry.id)
        case .bookmarks:
            guard row < bookmarks.count else { return }
            let bookmark = bookmarks[row]
            QueryHistoryManager.shared.deleteBookmark(id: bookmark.id)
        }
    }
}

// MARK: - NSTableViewDataSource

extension HistoryListViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch displayMode {
        case .history:
            return historyEntries.count
        case .bookmarks:
            return bookmarks.count
        }
    }
}

// MARK: - NSTableViewDelegate

extension HistoryListViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch displayMode {
        case .history:
            return historyCell(for: row)
        case .bookmarks:
            return bookmarkCell(for: row)
        }
    }

    private func historyCell(for row: Int) -> NSView? {
        guard row < historyEntries.count else { return nil }
        let entry = historyEntries[row]

        let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HistoryRowView
            ?? HistoryRowView()
        cell.identifier = identifier
        cell.configureForHistory(entry)
        return cell
    }

    private func bookmarkCell(for row: Int) -> NSView? {
        guard row < bookmarks.count else { return nil }
        let bookmark = bookmarks[row]

        let identifier = NSUserInterfaceItemIdentifier("BookmarkCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HistoryRowView
            ?? HistoryRowView()
        cell.identifier = identifier
        cell.configureForBookmark(bookmark)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else {
            delegate?.historyListViewControllerDidClearSelection(self)
            return
        }

        switch displayMode {
        case .history:
            guard row < historyEntries.count else { return }
            delegate?.historyListViewController(self, didSelectHistoryEntry: historyEntries[row])
        case .bookmarks:
            guard row < bookmarks.count else { return }
            delegate?.historyListViewController(self, didSelectBookmark: bookmarks[row])
        }
    }

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        if edge == .trailing {
            let delete = NSTableViewRowAction(style: .destructive, title: "Delete") { [weak self] _, row in
                self?.deleteEntryAtRow(row)
            }
            return [delete]
        }
        return []
    }

    private func deleteEntryAtRow(_ row: Int) {
        switch displayMode {
        case .history:
            guard row < historyEntries.count else { return }
            QueryHistoryManager.shared.deleteHistory(id: historyEntries[row].id)
        case .bookmarks:
            guard row < bookmarks.count else { return }
            QueryHistoryManager.shared.deleteBookmark(id: bookmarks[row].id)
        }
    }
}

// MARK: - NSSearchFieldDelegate

extension HistoryListViewController: NSSearchFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSearchField {
            searchText = field.stringValue
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            if !searchText.isEmpty {
                searchField.stringValue = ""
                searchText = ""
                return true
            }
        }
        return false
    }
}

// MARK: - NSMenuDelegate (Context Menu)

extension HistoryListViewController {

    override func rightMouseDown(with event: NSEvent) {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)

        if row >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let menu = buildContextMenu(for: row)
            NSMenu.popUpContextMenu(menu, with: event, for: tableView)
        }
    }
    
    // MARK: - Helper Methods
    
    func handleDeleteKey() {
        deleteSelectedRow()
    }
    
    /// Standard delete action for menu integration
    @objc func delete(_ sender: Any?) {
        deleteSelectedRow()
    }
    
    /// Standard copy action for menu integration (Cmd+C)
    @objc func copy(_ sender: Any?) {
        copyQueryForSelectedRow()
    }
    
    /// Validate menu items
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(delete(_:)) {
            let hasSelection = tableView.selectedRow >= 0
            let hasItems = displayMode == .history ? historyEntries.count > 0 : bookmarks.count > 0
            return hasSelection && hasItems
        }
        if menuItem.action == #selector(copy(_:)) {
            return tableView.selectedRow >= 0
        }
        return true
    }
    
    // MARK: - Keyboard Actions
    
    /// Handle Return/Enter key - open selected item in new tab
    func handleReturnKey() {
        runInNewTabForSelectedRow()
    }
    
    /// Handle Space key - toggle preview (currently just copies to show it's working)
    func handleSpaceKey() {
        // TODO: Implement preview panel toggle
        // For now, just show the query text in a temporary way
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        
        let query: String
        switch displayMode {
        case .history:
            guard row < historyEntries.count else { return }
            query = historyEntries[row].query
        case .bookmarks:
            guard row < bookmarks.count else { return }
            query = bookmarks[row].query
        }
        
        // Preview panel will be implemented in a future update
    }
    
    /// Handle Cmd+E - edit bookmark
    func handleEditBookmark() {
        guard displayMode == .bookmarks else { return }
        editBookmarkForSelectedRow()
    }
    
    /// Handle Escape key - clear search or selection
    func handleEscapeKey() {
        // If search field has text, clear it
        if !searchText.isEmpty {
            searchField.stringValue = ""
            searchText = ""
            searchField.window?.makeFirstResponder(tableView)
        } else if tableView.selectedRow >= 0 {
            // Otherwise clear selection
            tableView.deselectAll(nil)
        }
    }
    
    // MARK: - Keyboard Shortcut Helpers
    
    private func copyQueryForSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        
        
        let query: String
        switch displayMode {
        case .history:
            guard row < historyEntries.count else { return }
            query = historyEntries[row].query
        case .bookmarks:
            guard row < bookmarks.count else { return }
            query = bookmarks[row].query
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(query, forType: .string)
    }
    
    private func runInNewTabForSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0 else { 
            return 
        }
        
        
        let query: String
        switch displayMode {
        case .history:
            guard row < historyEntries.count else { 
                return 
            }
            query = historyEntries[row].query
        case .bookmarks:
            guard row < bookmarks.count else { 
                return 
            }
            query = bookmarks[row].query
            QueryHistoryManager.shared.markBookmarkUsed(id: bookmarks[row].id)
        }
        
        NotificationCenter.default.post(name: .newTab, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(
                name: .loadQueryIntoEditor,
                object: nil,
                userInfo: ["query": query]
            )
        }
    }
    
    private func saveAsBookmarkForSelectedRow() {
        let row = tableView.selectedRow
        guard displayMode == .history, row >= 0, row < historyEntries.count else { return }
        
        let entry = historyEntries[row]
        let editorView = BookmarkEditorView(
            query: entry.query,
            connectionId: entry.connectionId
        ) { [weak self] bookmark in
            let success = QueryHistoryManager.shared.saveBookmark(
                name: bookmark.name,
                query: bookmark.query,
                connectionId: bookmark.connectionId,
                tags: bookmark.tags,
                notes: bookmark.notes
            )
            
            if success {
            } else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Save Bookmark"
                    alert.informativeText = "Could not save the bookmark to storage. Please try again."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }

        presentAsSheet(editorView)
    }
    
    private func editBookmarkForSelectedRow() {
        let row = tableView.selectedRow
        guard displayMode == .bookmarks, row >= 0, row < bookmarks.count else { return }
        
        let bookmark = bookmarks[row]
        let editorView = BookmarkEditorView(
            bookmark: bookmark,
            query: bookmark.query,
            connectionId: bookmark.connectionId
        ) { [weak self] updatedBookmark in
            let success = QueryHistoryManager.shared.updateBookmark(updatedBookmark)
            
            if success {
            } else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Update Bookmark"
                    alert.informativeText = "Could not save changes to the bookmark. Please try again."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }

        presentAsSheet(editorView)
    }
    
    func deleteSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        
        
        // Store the count before deletion and row for smart selection
        let countBeforeDeletion: Int
        switch displayMode {
        case .history:
            countBeforeDeletion = historyEntries.count
        case .bookmarks:
            countBeforeDeletion = bookmarks.count
        }
        
        // Store for selection after reload
        pendingDeletionRow = row
        pendingDeletionCount = countBeforeDeletion
        
        // Perform deletion
        switch displayMode {
        case .history:
            guard row < historyEntries.count else { return }
            let entryId = historyEntries[row].id
            QueryHistoryManager.shared.deleteHistory(id: entryId)
            // Selection will happen in loadHistory() after notification
            
        case .bookmarks:
            guard row < bookmarks.count else { return }
            let bookmarkId = bookmarks[row].id
            let bookmarkName = bookmarks[row].name
            QueryHistoryManager.shared.deleteBookmark(id: bookmarkId)
            // Selection will happen in loadBookmarks() if notification triggers,
            // otherwise do it manually
        }
    }
    
    /// Select an appropriate row after deletion
    /// Selects the next row, or the previous row if the last item was deleted
    private func selectRowAfterDeletion(deletedRow: Int, countBefore: Int) {
        let currentCount: Int
        switch displayMode {
        case .history:
            currentCount = historyEntries.count
        case .bookmarks:
            currentCount = bookmarks.count
        }
        
        // If list is now empty, clear selection and delegate
        guard currentCount > 0 else {
            tableView.deselectAll(nil)
            delegate?.historyListViewControllerDidClearSelection(self)
            return
        }
        
        // Select next item if available, otherwise select previous
        let newSelection: Int
        if deletedRow < currentCount {
            // Next item moved into this position
            newSelection = deletedRow
        } else {
            // Deleted last item, select new last item
            newSelection = currentCount - 1
        }
        
        tableView.selectRowIndexes(IndexSet(integer: newSelection), byExtendingSelection: false)
        tableView.scrollRowToVisible(newSelection)
        
        // Notify delegate of new selection
        switch displayMode {
        case .history:
            if newSelection < historyEntries.count {
                delegate?.historyListViewController(self, didSelectHistoryEntry: historyEntries[newSelection])
            }
        case .bookmarks:
            if newSelection < bookmarks.count {
                delegate?.historyListViewController(self, didSelectBookmark: bookmarks[newSelection])
            }
        }
    }
}

// MARK: - HistoryRowView

final class HistoryRowView: NSTableCellView {

    private let statusIcon: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let queryLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let secondaryLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let timeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let durationLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var isSetup = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        guard !isSetup else { return }
        isSetup = true

        addSubview(statusIcon)
        addSubview(queryLabel)
        addSubview(secondaryLabel)
        addSubview(timeLabel)
        addSubview(durationLabel)

        NSLayoutConstraint.activate([
            // Status icon
            statusIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusIcon.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),

            // Query label (first line)
            queryLabel.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 8),
            queryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            queryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            // Secondary label (second line - database/tags)
            secondaryLabel.leadingAnchor.constraint(equalTo: queryLabel.leadingAnchor),
            secondaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            secondaryLabel.topAnchor.constraint(equalTo: queryLabel.bottomAnchor, constant: 2),

            // Time label (third line left)
            timeLabel.leadingAnchor.constraint(equalTo: queryLabel.leadingAnchor),
            timeLabel.topAnchor.constraint(equalTo: secondaryLabel.bottomAnchor, constant: 2),

            // Duration label (third line right)
            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            durationLabel.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: timeLabel.trailingAnchor, constant: 8)
        ])
    }

    func configureForHistory(_ entry: QueryHistoryEntry) {
        // Status icon
        let imageName = entry.wasSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill"
        statusIcon.image = NSImage(systemSymbolName: imageName, accessibilityDescription: entry.wasSuccessful ? "Success" : "Error")
        statusIcon.contentTintColor = entry.wasSuccessful ? .systemGreen : .systemRed

        // Query preview
        queryLabel.stringValue = entry.queryPreview

        // Database
        secondaryLabel.stringValue = entry.databaseName

        // Relative time
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        timeLabel.stringValue = formatter.localizedString(for: entry.executedAt, relativeTo: Date())

        // Duration
        durationLabel.stringValue = entry.formattedExecutionTime
    }

    func configureForBookmark(_ bookmark: QueryBookmark) {
        // Bookmark icon
        statusIcon.image = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Bookmark")
        statusIcon.contentTintColor = .systemYellow

        // Bookmark name
        queryLabel.stringValue = bookmark.name
        queryLabel.font = .systemFont(ofSize: 12, weight: .medium)

        // Tags
        secondaryLabel.stringValue = bookmark.hasTags ? bookmark.formattedTags : "No tags"

        // Created date
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        timeLabel.stringValue = dateFormatter.string(from: bookmark.createdAt)

        // Clear duration
        durationLabel.stringValue = ""
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        queryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusIcon.image = nil
        queryLabel.stringValue = ""
        secondaryLabel.stringValue = ""
        timeLabel.stringValue = ""
        durationLabel.stringValue = ""
    }
}

// MARK: - Custom TableView for Keyboard Handling

/// Custom table view for keyboard delegation
private class HistoryTableView: NSTableView, NSMenuItemValidation {
    weak var keyboardDelegate: HistoryListViewController?
    
    override var acceptsFirstResponder: Bool {
        return true
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
