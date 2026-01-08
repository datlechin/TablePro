//
//  HistoryPanelController.swift
//  TablePro
//
//  Main controller for history/bookmark panel with split-view layout
//

import AppKit

/// Main controller for the history/bookmark panel
/// Uses NSSplitView for master-detail layout: list on left, preview on right
final class HistoryPanelController: NSViewController {
    // MARK: - Child Controllers

    private let listController = HistoryListViewController()
    private let previewController = QueryPreviewViewController()

    // MARK: - UI Components

    private let splitView: NSSplitView = {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        return split
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSplitView()
        setupChildControllers()
        setupDelegates()
    }

    // MARK: - Setup

    private func setupSplitView() {
        view.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        splitView.delegate = self
    }

    private func setupChildControllers() {
        // Add list controller (left pane)
        addChild(listController)
        splitView.addArrangedSubview(listController.view)

        // Add preview controller (right pane)
        addChild(previewController)
        splitView.addArrangedSubview(previewController.view)

        // Set initial split position (40% for list, 60% for preview)
        splitView.setPosition(view.bounds.width * 0.4, ofDividerAt: 0)
    }

    private func setupDelegates() {
        listController.delegate = self
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        // Ensure minimum widths are respected
        if splitView.arrangedSubviews.count == 2 {
            let totalWidth = splitView.bounds.width
            let dividerThickness = splitView.dividerThickness
            let availableWidth = totalWidth - dividerThickness

            // Calculate positions respecting minimums
            let leftMinWidth: CGFloat = 200
            let rightMinWidth: CGFloat = 300

            if availableWidth >= leftMinWidth + rightMinWidth {
                // Use 40/60 split if space permits
                let leftWidth = max(leftMinWidth, availableWidth * 0.4)
                splitView.setPosition(leftWidth, ofDividerAt: 0)
            }
        }
    }
}

// MARK: - NSSplitViewDelegate

extension HistoryPanelController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Minimum width for left pane (list)
        200
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Maximum width for left pane (leaving 300pt minimum for right pane)
        splitView.bounds.width - 300
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }
}

// MARK: - HistoryListViewControllerDelegate

extension HistoryPanelController: HistoryListViewControllerDelegate {
    func historyListViewController(_ controller: HistoryListViewController, didSelectHistoryEntry entry: QueryHistoryEntry) {
        previewController.showHistoryEntry(entry)
    }

    func historyListViewController(_ controller: HistoryListViewController, didSelectBookmark bookmark: QueryBookmark) {
        previewController.showBookmark(bookmark)
    }

    func historyListViewController(_ controller: HistoryListViewController, didDoubleClickHistoryEntry entry: QueryHistoryEntry) {
        loadQueryIntoEditor(entry.query)
    }

    func historyListViewController(_ controller: HistoryListViewController, didDoubleClickBookmark bookmark: QueryBookmark) {
        loadQueryIntoEditor(bookmark.query)
        QueryHistoryManager.shared.markBookmarkUsed(id: bookmark.id)
    }

    func historyListViewControllerDidClearSelection(_ controller: HistoryListViewController) {
        previewController.clearPreview()
    }

    private func loadQueryIntoEditor(_ query: String) {
        NotificationCenter.default.post(
            name: .loadQueryIntoEditor,
            object: nil,
            userInfo: ["query": query]
        )
    }
}
