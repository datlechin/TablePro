//
//  HistoryListViewController.swift
//  TablePro
//
//  Left pane controller for history/bookmark list with search and filtering.
//  Child views and data provider extracted to separate files.
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

// MARK: - UI Date Filter

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

    private let dataProvider = HistoryDataProvider()

    private var displayMode: HistoryDisplayMode = .history {
        didSet {
            if oldValue != displayMode {
                dataProvider.displayMode = displayMode
                updateFilterVisibility()
                loadData()
            }
        }
    }

    private var dateFilter: UIDateFilter = .all {
        didSet {
            if oldValue != dateFilter {
                dataProvider.dateFilter = dateFilter
                loadData()
            }
        }
    }

    private var searchText: String = "" {
        didSet {
            dataProvider.searchText = searchText
            scheduleSearch()
        }
    }

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

    private lazy var clearAllButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear All")
        button.bezelStyle = .shadowlessSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(clearAllClicked(_:))
        button.toolTip = "Clear all \(displayMode == .history ? "history" : "bookmarks")"
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
        table.rowHeight = DesignConstants.RowHeight.comfortable
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.delegate = self
        table.dataSource = self
        table.doubleAction = #selector(tableViewDoubleClick(_:))
        table.target = self
        table.keyboardDelegate = self

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
        view.addSubview(headerView)

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let topRow = NSStackView(views: [modeSegment, NSView(), clearAllButton, filterButton])
        topRow.distribution = .fill
        topRow.spacing = 8

        headerStack.addArrangedSubview(topRow)
        headerStack.addArrangedSubview(searchField)

        headerView.addSubview(headerStack)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(divider)

        scrollView.documentView = tableView
        view.addSubview(scrollView)
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            headerStack.topAnchor.constraint(equalTo: headerView.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            headerStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),

            divider.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])

        updateFilterVisibility()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(historyDidUpdate), name: .queryHistoryDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(bookmarksDidUpdate), name: .queryBookmarksDidUpdate, object: nil)
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
        dataProvider.loadData()
        tableView.reloadData()
        updateEmptyState()

        if let deletedRow = pendingDeletionRow, let countBefore = pendingDeletionCount {
            selectRowAfterDeletion(deletedRow: deletedRow, countBefore: countBefore)
            pendingDeletionRow = nil
            pendingDeletionCount = nil
        } else if tableView.selectedRow < 0 {
            delegate?.historyListViewControllerDidClearSelection(self)
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        dataProvider.scheduleSearch { [weak self] in
            self?.tableView.reloadData()
            self?.updateEmptyState()
        }
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
            guard let entry = dataProvider.historyEntry(at: row) else { return }
            delegate?.historyListViewController(self, didDoubleClickHistoryEntry: entry)
        case .bookmarks:
            guard let bookmark = dataProvider.bookmark(at: row) else { return }
            delegate?.historyListViewController(self, didDoubleClickBookmark: bookmark)
        }
    }

    @objc private func historyDidUpdate() {
        if displayMode == .history { loadData() }
    }

    @objc private func bookmarksDidUpdate() {
        if displayMode == .bookmarks { loadData() }
    }

    @objc private func clearAllClicked(_ sender: Any?) {
        let count = dataProvider.count
        let itemName = count == 1 ? (displayMode == .history ? "history entry" : "bookmark") : (displayMode == .history ? "history entries" : "bookmarks")

        guard count > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Clear All \(displayMode == .history ? "History" : "Bookmarks")?"
        alert.informativeText = "This will permanently delete \(count) \(itemName). This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            _ = dataProvider.clearAll()
        }
    }

    // MARK: - UI Updates

    private func updateFilterVisibility() {
        filterButton.isHidden = displayMode == .bookmarks
        searchField.placeholderString = displayMode == .history ? "Search queries..." : "Search bookmarks..."
    }

    private func updateEmptyState() {
        let isEmpty = dataProvider.isEmpty
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
        guard let query = dataProvider.query(at: sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(query, forType: .string)
    }

    @objc private func runInNewTab(_ sender: NSMenuItem) {
        guard let query = dataProvider.query(at: sender.tag) else { return }

        if displayMode == .bookmarks {
            dataProvider.markBookmarkUsed(at: sender.tag)
        }

        NotificationCenter.default.post(name: .newTab, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .loadQueryIntoEditor, object: query)
        }
    }

    @objc private func saveAsBookmark(_ sender: NSMenuItem) {
        guard let entry = dataProvider.historyEntry(at: sender.tag) else { return }

        let editor = BookmarkEditorController(bookmark: nil, query: entry.query, connectionId: entry.connectionId)
        editor.onSave = { bookmark in
            _ = QueryHistoryManager.shared.saveBookmark(
                name: bookmark.name,
                query: bookmark.query,
                connectionId: bookmark.connectionId,
                tags: bookmark.tags,
                notes: bookmark.notes
            )
        }
        view.window?.contentViewController?.presentAsSheet(editor)
    }

    @objc private func editBookmark(_ sender: NSMenuItem) {
        guard let bookmark = dataProvider.bookmark(at: sender.tag) else { return }

        let editorView = BookmarkEditorView(bookmark: bookmark, query: bookmark.query, connectionId: bookmark.connectionId) { updatedBookmark in
            _ = QueryHistoryManager.shared.updateBookmark(updatedBookmark)
        }
        presentAsSheet(editorView)
    }

    @objc private func deleteEntry(_ sender: NSMenuItem) {
        _ = dataProvider.deleteItem(at: sender.tag)
    }

    // MARK: - Selection After Deletion

    private func selectRowAfterDeletion(deletedRow: Int, countBefore: Int) {
        let currentCount = dataProvider.count

        guard currentCount > 0 else {
            tableView.deselectAll(nil)
            delegate?.historyListViewControllerDidClearSelection(self)
            return
        }

        let newSelection = deletedRow < currentCount ? deletedRow : currentCount - 1
        tableView.selectRowIndexes(IndexSet(integer: newSelection), byExtendingSelection: false)
        tableView.scrollRowToVisible(newSelection)

        switch displayMode {
        case .history:
            if let entry = dataProvider.historyEntry(at: newSelection) {
                delegate?.historyListViewController(self, didSelectHistoryEntry: entry)
            }
        case .bookmarks:
            if let bookmark = dataProvider.bookmark(at: newSelection) {
                delegate?.historyListViewController(self, didSelectBookmark: bookmark)
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension HistoryListViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        dataProvider.count
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
        guard let entry = dataProvider.historyEntry(at: row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HistoryRowView ?? HistoryRowView()
        cell.identifier = identifier
        cell.configureForHistory(entry)
        return cell
    }

    private func bookmarkCell(for row: Int) -> NSView? {
        guard let bookmark = dataProvider.bookmark(at: row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("BookmarkCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HistoryRowView ?? HistoryRowView()
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
            if let entry = dataProvider.historyEntry(at: row) {
                delegate?.historyListViewController(self, didSelectHistoryEntry: entry)
            }
        case .bookmarks:
            if let bookmark = dataProvider.bookmark(at: row) {
                delegate?.historyListViewController(self, didSelectBookmark: bookmark)
            }
        }
    }

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        if edge == .trailing {
            let delete = NSTableViewRowAction(style: .destructive, title: "Delete") { [weak self] _, row in
                _ = self?.dataProvider.deleteItem(at: row)
            }
            return [delete]
        }
        return []
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

// MARK: - Context Menu

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
}

// MARK: - HistoryTableViewKeyboardDelegate

extension HistoryListViewController: HistoryTableViewKeyboardDelegate {
    func handleDeleteKey() {
        deleteSelectedRow()
    }

    @objc func delete(_ sender: Any?) {
        deleteSelectedRow()
    }

    @objc func copy(_ sender: Any?) {
        copyQueryForSelectedRow()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(delete(_:)) {
            return tableView.selectedRow >= 0 && !dataProvider.isEmpty
        }
        if menuItem.action == #selector(copy(_:)) {
            return tableView.selectedRow >= 0
        }
        return true
    }

    func handleReturnKey() {
        runInNewTabForSelectedRow()
    }

    func handleSpaceKey() {
        // Preview panel - future implementation
    }

    func handleEditBookmark() {
        guard displayMode == .bookmarks else { return }
        editBookmarkForSelectedRow()
    }

    func handleEscapeKey() {
        if !searchText.isEmpty {
            searchField.stringValue = ""
            searchText = ""
            searchField.window?.makeFirstResponder(tableView)
        } else if tableView.selectedRow >= 0 {
            tableView.deselectAll(nil)
        }
    }

    func deleteSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }

        pendingDeletionRow = row
        pendingDeletionCount = dataProvider.count
        _ = dataProvider.deleteItem(at: row)
    }

    private func copyQueryForSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0, let query = dataProvider.query(at: row) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(query, forType: .string)
    }

    private func runInNewTabForSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0, let query = dataProvider.query(at: row) else { return }

        if displayMode == .bookmarks {
            dataProvider.markBookmarkUsed(at: row)
        }

        NotificationCenter.default.post(name: .newTab, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .loadQueryIntoEditor, object: query)
        }
    }

    private func editBookmarkForSelectedRow() {
        let row = tableView.selectedRow
        guard let bookmark = dataProvider.bookmark(at: row) else { return }

        let editorView = BookmarkEditorView(bookmark: bookmark, query: bookmark.query, connectionId: bookmark.connectionId) { updatedBookmark in
            _ = QueryHistoryManager.shared.updateBookmark(updatedBookmark)
        }
        presentAsSheet(editorView)
    }
}
