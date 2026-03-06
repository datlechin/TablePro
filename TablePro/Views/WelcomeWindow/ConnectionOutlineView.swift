//
//  ConnectionOutlineView.swift
//  TablePro
//
//  NSViewRepresentable wrapping NSOutlineView for hierarchical connection list
//  with drag-and-drop reordering and group management.
//

import AppKit
import os
import SwiftUI

// MARK: - Outline Item Wrappers

/// Reference-type wrapper for ConnectionGroup (NSOutlineView requires objects)
final class OutlineGroup: NSObject {
    let group: ConnectionGroup
    init(_ group: ConnectionGroup) {
        self.group = group
    }
}

/// Reference-type wrapper for DatabaseConnection (NSOutlineView requires objects)
final class OutlineConnection: NSObject {
    let connection: DatabaseConnection
    init(_ connection: DatabaseConnection) {
        self.connection = connection
    }
}

// MARK: - ConnectionOutlineView

struct ConnectionOutlineView: NSViewRepresentable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionOutlineView")

    let groups: [ConnectionGroup]
    let connections: [DatabaseConnection]
    var expandedGroupIds: Set<UUID>
    var searchText: String

    // Callbacks
    var onDoubleClickConnection: ((DatabaseConnection) -> Void)?
    var onToggleGroup: ((UUID) -> Void)?
    var onReorderConnections: (([DatabaseConnection]) -> Void)?
    var onReorderGroups: (([ConnectionGroup]) -> Void)?
    var onMoveGroup: ((ConnectionGroup, UUID?) -> Void)?

    // Context menu callbacks
    var onNewConnection: (() -> Void)?
    var onNewGroup: ((UUID?) -> Void)?
    var onEditGroup: ((ConnectionGroup) -> Void)?
    var onEditConnection: ((DatabaseConnection) -> Void)?
    var onDuplicateConnection: ((DatabaseConnection) -> Void)?
    var onCopyConnectionURL: ((DatabaseConnection) -> Void)?
    var onMoveConnectionToGroup: ((DatabaseConnection, UUID?) -> Void)?

    // Delete & bulk callbacks
    var onRequestDelete: (([ConnectionGroup], [DatabaseConnection]) -> Void)?
    var onMoveConnectionsToGroup: (([DatabaseConnection], UUID?) -> Void)?

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = ConnectionNSOutlineView()
        outlineView.coordinator = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.title = ""
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.headerView = nil
        outlineView.rowHeight = DesignConstants.RowHeight.comfortable
        outlineView.style = .sourceList
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsMultipleSelection = true
        outlineView.autosaveExpandedItems = false
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.usesAutomaticRowHeights = false
        outlineView.indentationPerLevel = 20
        outlineView.backgroundColor = .clear

        outlineView.registerForDraggedTypes([.outlineItem])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.handleDoubleClick)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false

        context.coordinator.outlineView = outlineView
        context.coordinator.rebuildData(groups: groups, connections: connections, searchText: searchText)
        outlineView.reloadData()
        restoreExpandedState(outlineView: outlineView, coordinator: context.coordinator, expandedIds: expandedGroupIds)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let outlineView = scrollView.documentView as? NSOutlineView else { return }

        let coordinator = context.coordinator
        coordinator.parent = self

        // Skip reload during active drag to avoid lag
        guard !coordinator.isDragging else { return }

        let needsReload = coordinator.needsReload(
            groups: groups,
            connections: connections,
            searchText: searchText
        )

        if needsReload {
            // Capture current state before reload destroys it
            let currentExpanded = coordinator.captureExpandedGroupIds(from: outlineView)
            let scrollView = outlineView.enclosingScrollView
            let savedOrigin = scrollView?.contentView.bounds.origin

            coordinator.rebuildData(groups: groups, connections: connections, searchText: searchText)
            outlineView.reloadData()

            restoreExpandedState(
                outlineView: outlineView,
                coordinator: coordinator,
                expandedIds: currentExpanded.union(expandedGroupIds)
            )

            // Restore scroll position, clamped to new content bounds
            if let scrollView, let savedOrigin {
                let maxY = max(0, outlineView.frame.height - scrollView.contentView.bounds.height)
                let clampedY = min(savedOrigin.y, maxY)
                scrollView.contentView.scroll(to: NSPoint(x: savedOrigin.x, y: clampedY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    // MARK: - State Sync

    /// Restore expanded state after a reload using the given set of IDs.
    private func restoreExpandedState(
        outlineView: NSOutlineView,
        coordinator: Coordinator,
        expandedIds: Set<UUID>
    ) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        for item in coordinator.rootItems {
            restoreExpandedStateRecursive(
                outlineView: outlineView, item: item, coordinator: coordinator, expandedIds: expandedIds
            )
        }

        NSAnimationContext.endGrouping()
    }

    private func restoreExpandedStateRecursive(
        outlineView: NSOutlineView,
        item: NSObject,
        coordinator: Coordinator,
        expandedIds: Set<UUID>
    ) {
        guard let outlineGroup = item as? OutlineGroup else { return }
        if expandedIds.contains(outlineGroup.group.id) {
            outlineView.expandItem(item)
        }
        if let children = coordinator.childrenMap[outlineGroup.group.id] {
            for child in children {
                restoreExpandedStateRecursive(
                    outlineView: outlineView, item: child, coordinator: coordinator, expandedIds: expandedIds
                )
            }
        }
    }

}

// MARK: - Pasteboard Type

private extension NSPasteboard.PasteboardType {
    static let outlineItem = NSPasteboard.PasteboardType("com.TablePro.outlineItem")
}

// MARK: - Cell View Identifiers

private extension NSUserInterfaceItemIdentifier {
    static let groupCell = NSUserInterfaceItemIdentifier("GroupCell")
    static let connectionCell = NSUserInterfaceItemIdentifier("ConnectionCell")
}

// MARK: - Reusable Cell Views

/// Cell view for group rows — subviews are created once and updated on reuse
private final class GroupCellView: NSTableCellView {
    let folderIcon = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .groupCell
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setupViews() {
        let iconSize = DesignConstants.IconSize.medium

        folderIcon.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        folderIcon.heightAnchor.constraint(equalToConstant: iconSize).isActive = true

        nameLabel.font = NSFont.systemFont(ofSize: DesignConstants.FontSize.body, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countLabel.font = NSFont.systemFont(ofSize: DesignConstants.FontSize.small)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let container = NSStackView(views: [folderIcon, nameLabel, countLabel])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = DesignConstants.Spacing.xs
        container.translatesAutoresizingMaskIntoConstraints = false

        addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignConstants.Spacing.xxs),
            container.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DesignConstants.Spacing.xs),
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        textField = nameLabel
        imageView = folderIcon
    }

    func configure(group: ConnectionGroup, connectionCount: Int) {
        let folderImage = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        folderIcon.image = folderImage
        folderIcon.contentTintColor = group.color.isDefault ? .secondaryLabelColor : NSColor(group.color.color)
        nameLabel.stringValue = group.name
        countLabel.stringValue = "\(connectionCount)"
    }
}

/// Cell view for connection rows — subviews are created once and updated on reuse
private final class ConnectionCellView: NSTableCellView {
    let dbIcon = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let tagLabel = NSTextField(labelWithString: "")
    let tagWrapper = NSView()
    private let titleStack: NSStackView

    override init(frame frameRect: NSRect) {
        titleStack = NSStackView()
        super.init(frame: frameRect)
        identifier = .connectionCell
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setupViews() {
        let iconSize = DesignConstants.IconSize.medium

        dbIcon.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        dbIcon.translatesAutoresizingMaskIntoConstraints = false
        dbIcon.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        dbIcon.heightAnchor.constraint(equalToConstant: iconSize).isActive = true

        nameLabel.font = NSFont.systemFont(ofSize: DesignConstants.FontSize.body, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Tag badge setup
        tagLabel.font = NSFont.systemFont(ofSize: DesignConstants.FontSize.tiny)
        tagLabel.drawsBackground = false
        tagLabel.isBordered = false
        tagLabel.isEditable = false
        tagLabel.translatesAutoresizingMaskIntoConstraints = false

        tagWrapper.wantsLayer = true
        tagWrapper.layer?.cornerRadius = DesignConstants.CornerRadius.small
        tagWrapper.layer?.masksToBounds = true
        tagWrapper.translatesAutoresizingMaskIntoConstraints = false
        tagWrapper.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        tagWrapper.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        tagWrapper.addSubview(tagLabel)
        let paddingH = DesignConstants.Spacing.xxs
        let paddingV = DesignConstants.Spacing.xxxs
        NSLayoutConstraint.activate([
            tagLabel.leadingAnchor.constraint(equalTo: tagWrapper.leadingAnchor, constant: paddingH),
            tagLabel.trailingAnchor.constraint(equalTo: tagWrapper.trailingAnchor, constant: -paddingH),
            tagLabel.topAnchor.constraint(equalTo: tagWrapper.topAnchor, constant: paddingV),
            tagLabel.bottomAnchor.constraint(equalTo: tagWrapper.bottomAnchor, constant: -paddingV),
        ])

        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = DesignConstants.Spacing.xxs + 2
        titleStack.addArrangedSubview(nameLabel)
        titleStack.addArrangedSubview(tagWrapper)

        subtitleLabel.font = NSFont.systemFont(ofSize: DesignConstants.FontSize.small)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleStack, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = DesignConstants.Spacing.xxxs
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let container = NSStackView(views: [dbIcon, textStack])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = DesignConstants.Spacing.sm
        container.translatesAutoresizingMaskIntoConstraints = false

        addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignConstants.Spacing.xxs),
            container.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DesignConstants.Spacing.xs),
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        textField = nameLabel
        imageView = dbIcon
    }

    func configure(connection: DatabaseConnection) {
        // Icon
        if let assetImage = NSImage(named: connection.type.iconName) {
            let templateImage = assetImage.copy() as? NSImage ?? assetImage
            templateImage.isTemplate = true
            dbIcon.image = templateImage
            dbIcon.contentTintColor = NSColor(connection.displayColor)
        }

        // Name
        nameLabel.stringValue = connection.name

        // Tag
        if let tagId = connection.tagId, let tag = TagStorage.shared.tag(for: tagId) {
            tagLabel.stringValue = tag.name
            tagLabel.textColor = NSColor(tag.color.color)
            tagWrapper.layer?.backgroundColor = NSColor(tag.color.color).withAlphaComponent(0.15).cgColor
            tagWrapper.isHidden = false
        } else {
            tagWrapper.isHidden = true
        }

        // Subtitle
        if connection.sshConfig.enabled {
            subtitleLabel.stringValue = "SSH : \(connection.sshConfig.username)@\(connection.sshConfig.host)"
        } else if connection.host.isEmpty {
            subtitleLabel.stringValue = connection.database.isEmpty ? connection.type.rawValue : connection.database
        } else {
            subtitleLabel.stringValue = connection.host
        }
    }
}

// MARK: - ConnectionNSOutlineView

/// Custom NSOutlineView subclass for context menus and keyboard handling
final class ConnectionNSOutlineView: NSOutlineView {
    weak var coordinator: ConnectionOutlineView.Coordinator?

    override func drawBackground(inClipRect clipRect: NSRect) {
        // Skip the translucent gray; SwiftUI parent background shows through
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        if clickedRow >= 0 {
            // If clicked row is already in selection, keep multi-selection
            if !selectedRowIndexes.contains(clickedRow) {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }

            // Multi-selection context menu
            if selectedRowIndexes.count > 1 {
                return coordinator?.multiSelectionContextMenu(outlineView: self)
            }

            let item = self.item(atRow: clickedRow)
            if let outlineGroup = item as? OutlineGroup {
                return coordinator?.contextMenu(for: outlineGroup)
            } else if let outlineConn = item as? OutlineConnection {
                return coordinator?.contextMenu(for: outlineConn)
            }
        }

        return coordinator?.emptySpaceContextMenu()
    }

    override func keyDown(with event: NSEvent) {
        // Return key on a connection triggers double-click action
        if event.keyCode == 36 {
            let row = selectedRow
            if row >= 0, let outlineConn = item(atRow: row) as? OutlineConnection {
                coordinator?.parent.onDoubleClickConnection?(outlineConn.connection)
                return
            }
            // Return on a group toggles expand/collapse
            if row >= 0, let outlineGroup = item(atRow: row) as? OutlineGroup {
                coordinator?.parent.onToggleGroup?(outlineGroup.group.id)
                return
            }
        }
        // Delete/Backspace key deletes selected items
        if event.keyCode == 51, !selectedRowIndexes.isEmpty {
            var selectedConnections: [DatabaseConnection] = []
            var selectedGroups: [ConnectionGroup] = []
            for row in selectedRowIndexes {
                if let outlineConn = item(atRow: row) as? OutlineConnection {
                    selectedConnections.append(outlineConn.connection)
                } else if let outlineGroup = item(atRow: row) as? OutlineGroup {
                    selectedGroups.append(outlineGroup.group)
                }
            }
            if !selectedGroups.isEmpty || !selectedConnections.isEmpty {
                coordinator?.parent.onRequestDelete?(selectedGroups, selectedConnections)
            }
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Coordinator

extension ConnectionOutlineView {
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionOutlineView.Coordinator")

        var parent: ConnectionOutlineView
        weak var outlineView: ConnectionNSOutlineView?
        var isDragging = false
        private var draggedItemId: UUID?
        private var draggedItemIds: Set<UUID> = []

        // Data model
        var rootItems: [NSObject] = []
        var childrenMap: [UUID: [NSObject]] = [:]
        private var allGroupItems: [UUID: OutlineGroup] = [:]
        private var allConnectionItems: [UUID: OutlineConnection] = [:]
        private var isSearchMode = false

        // Snapshot for change detection
        private var lastSnapshotHash = 0

        init(parent: ConnectionOutlineView) {
            self.parent = parent
        }

        // MARK: - Data Building

        func needsReload(groups: [ConnectionGroup], connections: [DatabaseConnection], searchText: String) -> Bool {
            let hash = computeSnapshotHash(groups: groups, connections: connections, searchText: searchText)
            return hash != lastSnapshotHash
        }

        private func computeSnapshotHash(groups: [ConnectionGroup], connections: [DatabaseConnection], searchText: String) -> Int {
            var hasher = Hasher()
            hasher.combine(searchText)
            for g in groups {
                hasher.combine(g.id)
                hasher.combine(g.sortOrder)
                hasher.combine(g.parentGroupId)
                hasher.combine(g.name)
                hasher.combine(g.color)
            }
            for c in connections {
                hasher.combine(c.id)
                hasher.combine(c.sortOrder)
                hasher.combine(c.groupId)
                hasher.combine(c.name)
                hasher.combine(c.host)
                hasher.combine(c.tagId)
            }
            return hasher.finalize()
        }

        func rebuildData(groups: [ConnectionGroup], connections: [DatabaseConnection], searchText: String) {
            rootItems.removeAll()
            childrenMap.removeAll()
            allGroupItems.removeAll()
            allConnectionItems.removeAll()
            isSearchMode = !searchText.isEmpty

            lastSnapshotHash = computeSnapshotHash(groups: groups, connections: connections, searchText: searchText)

            if isSearchMode {
                // In search mode, `connections` is already filtered by the caller.
                // Build a flat, sorted list of those connections.
                let sortedConnections = connections.sorted { $0.sortOrder < $1.sortOrder }

                for conn in sortedConnections {
                    let item = OutlineConnection(conn)
                    allConnectionItems[conn.id] = item
                    rootItems.append(item)
                }
                return
            }

            // Build group items
            for group in groups {
                let item = OutlineGroup(group)
                allGroupItems[group.id] = item
            }

            // Build connection items
            for conn in connections {
                let item = OutlineConnection(conn)
                allConnectionItems[conn.id] = item
            }

            // Build children map for each group
            for group in groups {
                var children: [NSObject] = []

                // Child groups sorted by sortOrder
                let childGroups = groups
                    .filter { $0.parentGroupId == group.id }
                    .sorted { $0.sortOrder < $1.sortOrder }
                for child in childGroups {
                    if let item = allGroupItems[child.id] {
                        children.append(item)
                    }
                }

                // Connections in this group sorted by sortOrder
                let groupConns = connections
                    .filter { $0.groupId == group.id }
                    .sorted { $0.sortOrder < $1.sortOrder }
                for conn in groupConns {
                    if let item = allConnectionItems[conn.id] {
                        children.append(item)
                    }
                }

                childrenMap[group.id] = children
            }

            // Root items: root groups (parentGroupId == nil) sorted by sortOrder,
            // then ungrouped connections (groupId == nil) sorted by sortOrder
            let rootGroups = groups
                .filter { $0.parentGroupId == nil }
                .sorted { $0.sortOrder < $1.sortOrder }
            for group in rootGroups {
                if let item = allGroupItems[group.id] {
                    rootItems.append(item)
                }
            }

            let ungroupedConns = connections
                .filter { $0.groupId == nil }
                .sorted { $0.sortOrder < $1.sortOrder }
            for conn in ungroupedConns {
                if let item = allConnectionItems[conn.id] {
                    rootItems.append(item)
                }
            }
        }

        func itemById(_ id: UUID) -> NSObject? {
            if let item = allGroupItems[id] {
                return item
            }
            return allConnectionItems[id]
        }

        /// Capture which group IDs are currently expanded in the outline view.
        func captureExpandedGroupIds(from outlineView: NSOutlineView) -> Set<UUID> {
            var expanded = Set<UUID>()
            for (groupId, item) in allGroupItems {
                if outlineView.isItemExpanded(item) {
                    expanded.insert(groupId)
                }
            }
            return expanded
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil {
                return rootItems.count
            }
            if let outlineGroup = item as? OutlineGroup {
                return childrenMap[outlineGroup.group.id]?.count ?? 0
            }
            return 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return rootItems[index]
            }
            if let outlineGroup = item as? OutlineGroup,
               let children = childrenMap[outlineGroup.group.id]
            {
                return children[index]
            }
            return NSObject()
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            if let outlineGroup = item as? OutlineGroup {
                let children = childrenMap[outlineGroup.group.id] ?? []
                return !children.isEmpty
            }
            return false
        }

        // MARK: - Drag Source

        func outlineView(
            _ outlineView: NSOutlineView,
            pasteboardWriterForItem item: Any
        ) -> (any NSPasteboardWriting)? {
            // Disable drag in search mode
            guard !isSearchMode else { return nil }

            isDragging = true

            // On first item of a drag, capture all selected IDs
            if draggedItemIds.isEmpty {
                var hasGroup = false
                var hasConnection = false
                for row in outlineView.selectedRowIndexes {
                    if outlineView.item(atRow: row) is OutlineGroup {
                        hasGroup = true
                    } else if outlineView.item(atRow: row) is OutlineConnection {
                        hasConnection = true
                    }
                }
                // Don't allow multi-drag when groups are involved (moving a parent already moves children)
                let isMultiSelection = outlineView.selectedRowIndexes.count > 1
                if isMultiSelection, hasGroup {
                    isDragging = false
                    return nil
                }

                for row in outlineView.selectedRowIndexes {
                    if let conn = outlineView.item(atRow: row) as? OutlineConnection {
                        draggedItemIds.insert(conn.connection.id)
                    }
                }
            }

            // If multi-drag was blocked, reject subsequent items too
            if !isDragging { return nil }

            let pasteboardItem = NSPasteboardItem()
            if let outlineGroup = item as? OutlineGroup {
                draggedItemId = outlineGroup.group.id
                pasteboardItem.setString(outlineGroup.group.id.uuidString, forType: .outlineItem)
            } else if let outlineConn = item as? OutlineConnection {
                draggedItemId = outlineConn.connection.id
                pasteboardItem.setString(outlineConn.connection.id.uuidString, forType: .outlineItem)
            }
            return pasteboardItem
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            isDragging = false
            draggedItemId = nil
            draggedItemIds = []
        }

        // MARK: - Drop Validation

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: any NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard let draggedId = draggedItemId else { return [] }

            let isDraggingGroup = allGroupItems[draggedId] != nil
            let isDraggingConnection = allConnectionItems[draggedId] != nil

            if isDraggingConnection {
                return validateConnectionDrop(
                    outlineView: outlineView,
                    draggedId: draggedId,
                    proposedItem: item,
                    proposedChildIndex: index
                )
            }

            if isDraggingGroup {
                return validateGroupDrop(
                    outlineView: outlineView,
                    draggedId: draggedId,
                    proposedItem: item,
                    proposedChildIndex: index
                )
            }

            return []
        }

        private func validateConnectionDrop(
            outlineView: NSOutlineView,
            draggedId: UUID,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            if item == nil {
                // Dropping at root level: ungroup
                return .move
            }

            if item is OutlineGroup {
                // Dropping into/within a group
                return .move
            }

            if let outlineConn = item as? OutlineConnection {
                // Proposed target is a connection: retarget to its parent group
                let parentGroupId = outlineConn.connection.groupId
                if let parentGroupId, let parentItem = allGroupItems[parentGroupId] {
                    let children = childrenMap[parentGroupId] ?? []
                    let childIndex = children.firstIndex(where: { ($0 as? OutlineConnection)?.connection.id == outlineConn.connection.id })
                    outlineView.setDropItem(parentItem, dropChildIndex: childIndex ?? children.count)
                } else {
                    // Connection is at root: retarget to root
                    let rootIndex = rootItems.firstIndex(where: { ($0 as? OutlineConnection)?.connection.id == outlineConn.connection.id })
                    outlineView.setDropItem(nil, dropChildIndex: rootIndex ?? rootItems.count)
                }
                return .move
            }

            return []
        }

        private func validateGroupDrop(
            outlineView: NSOutlineView,
            draggedId: UUID,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            // Prevent dropping a group into itself or its descendants
            if let targetGroup = item as? OutlineGroup {
                if targetGroup.group.id == draggedId {
                    return []
                }
                if isDescendant(groupId: targetGroup.group.id, ofGroupId: draggedId) {
                    return []
                }
                return .move
            }

            // Root drop
            if item == nil {
                return .move
            }

            // Dropping onto a connection: retarget to the connection's parent
            if let outlineConn = item as? OutlineConnection {
                let parentGroupId = outlineConn.connection.groupId
                if let parentGroupId, let parentItem = allGroupItems[parentGroupId] {
                    if parentGroupId == draggedId || isDescendant(groupId: parentGroupId, ofGroupId: draggedId) {
                        return []
                    }
                    let children = childrenMap[parentGroupId] ?? []
                    let childIndex = children.firstIndex(where: { ($0 as? OutlineConnection)?.connection.id == outlineConn.connection.id })
                    outlineView.setDropItem(parentItem, dropChildIndex: childIndex ?? children.count)
                } else {
                    let rootIndex = rootItems.firstIndex(where: { ($0 as? OutlineConnection)?.connection.id == outlineConn.connection.id })
                    outlineView.setDropItem(nil, dropChildIndex: rootIndex ?? rootItems.count)
                }
                return .move
            }

            return []
        }

        /// Check if a group is a descendant of another group
        private func isDescendant(groupId: UUID, ofGroupId ancestorId: UUID) -> Bool {
            guard let children = childrenMap[ancestorId] else { return false }
            for child in children {
                guard let childGroup = child as? OutlineGroup else { continue }
                if childGroup.group.id == groupId {
                    return true
                }
                if isDescendant(groupId: groupId, ofGroupId: childGroup.group.id) {
                    return true
                }
            }
            return false
        }

        // MARK: - Accept Drop

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: any NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            guard let pasteboardItem = info.draggingPasteboard.pasteboardItems?.first,
                  let uuidString = pasteboardItem.string(forType: .outlineItem),
                  let draggedId = UUID(uuidString: uuidString)
            else {
                return false
            }

            // Capture all dragged IDs before clearing state
            let allDraggedIds = draggedItemIds.isEmpty ? [draggedId] : draggedItemIds

            // Clear drag state before callbacks so the subsequent
            // SwiftUI state update → updateNSView is not blocked
            isDragging = false
            draggedItemId = nil
            draggedItemIds = []

            // Collect all dragged connections and groups
            let draggedConnections = allDraggedIds.compactMap { allConnectionItems[$0]?.connection }
            let draggedGroups = allDraggedIds.compactMap { allGroupItems[$0]?.group }

            // Multi-connection drop
            if !draggedConnections.isEmpty, draggedGroups.isEmpty {
                return acceptMultiConnectionDrop(
                    connections: draggedConnections,
                    targetItem: item,
                    childIndex: index
                )
            }

            // Single group drop (multi-group drag not supported)
            if let draggedGroupItem = allGroupItems[draggedId] {
                return acceptGroupDrop(
                    group: draggedGroupItem.group,
                    targetItem: item,
                    childIndex: index
                )
            }

            return false
        }

        private func acceptConnectionDrop(
            connection: DatabaseConnection,
            targetItem: Any?,
            childIndex: Int
        ) -> Bool {
            if let targetGroup = targetItem as? OutlineGroup {
                let targetGroupId = targetGroup.group.id

                if childIndex == NSOutlineViewDropOnItemIndex {
                    // Dropped ON the group: move to end
                    var movedConn = connection
                    movedConn.groupId = targetGroupId
                    var siblings = parent.connections
                        .filter { $0.groupId == targetGroupId && $0.id != connection.id }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    movedConn.sortOrder = (siblings.last?.sortOrder ?? -1) + 1
                    siblings.append(movedConn)
                    parent.onReorderConnections?(siblings)
                } else {
                    // Dropped at a specific index within the group
                    var siblings = parent.connections
                        .filter { $0.groupId == targetGroupId && $0.id != connection.id }
                        .sorted { $0.sortOrder < $1.sortOrder }

                    let childGroups = childrenMap[targetGroupId]?.compactMap { $0 as? OutlineGroup } ?? []
                    let connectionIndex = max(0, childIndex - childGroups.count)

                    var movedConn = connection
                    movedConn.groupId = targetGroupId
                    siblings.insert(movedConn, at: min(connectionIndex, siblings.count))

                    for (order, var conn) in siblings.enumerated() {
                        conn.sortOrder = order
                        siblings[order] = conn
                    }
                    parent.onReorderConnections?(siblings)
                }
                return true
            }

            if targetItem == nil {
                if childIndex == NSOutlineViewDropOnItemIndex {
                    // Dropped ON root: just ungroup, append at end
                    var movedConn = connection
                    movedConn.groupId = nil
                    var rootConns = parent.connections
                        .filter { $0.groupId == nil && $0.id != connection.id }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    movedConn.sortOrder = (rootConns.last?.sortOrder ?? -1) + 1
                    rootConns.append(movedConn)
                    parent.onReorderConnections?(rootConns)
                } else {
                    var rootConns = parent.connections
                        .filter { $0.groupId == nil && $0.id != connection.id }
                        .sorted { $0.sortOrder < $1.sortOrder }

                    let rootGroupCount = rootItems.compactMap { $0 as? OutlineGroup }.count
                    let connectionIndex = max(0, childIndex - rootGroupCount)

                    var movedConn = connection
                    movedConn.groupId = nil
                    rootConns.insert(movedConn, at: min(connectionIndex, rootConns.count))

                    for (order, var conn) in rootConns.enumerated() {
                        conn.sortOrder = order
                        rootConns[order] = conn
                    }
                    parent.onReorderConnections?(rootConns)
                }
                return true
            }

            return false
        }

        private func acceptMultiConnectionDrop(
            connections: [DatabaseConnection],
            targetItem: Any?,
            childIndex: Int
        ) -> Bool {
            // Single connection: use existing logic
            if connections.count == 1 {
                return acceptConnectionDrop(
                    connection: connections[0],
                    targetItem: targetItem,
                    childIndex: childIndex
                )
            }

            let draggedIds = Set(connections.map(\.id))
            let targetGroupId: UUID? = (targetItem as? OutlineGroup)?.group.id

            // Get existing siblings excluding dragged items
            var siblings = parent.connections
                .filter { $0.groupId == targetGroupId && !draggedIds.contains($0.id) }
                .sorted { $0.sortOrder < $1.sortOrder }

            // Append all dragged connections at the end
            for var conn in connections {
                conn.groupId = targetGroupId
                conn.sortOrder = (siblings.last?.sortOrder ?? -1) + 1
                siblings.append(conn)
            }

            // Renumber
            for (order, var conn) in siblings.enumerated() {
                conn.sortOrder = order
                siblings[order] = conn
            }

            parent.onReorderConnections?(siblings)
            return true
        }

        private func acceptGroupDrop(
            group: ConnectionGroup,
            targetItem: Any?,
            childIndex: Int
        ) -> Bool {
            if let targetGroup = targetItem as? OutlineGroup {
                let newParentId = targetGroup.group.id

                if childIndex == NSOutlineViewDropOnItemIndex {
                    // Dropped ON the group: move as last child
                    var movedGroup = group
                    movedGroup.parentGroupId = newParentId
                    var siblings = parent.groups
                        .filter { $0.parentGroupId == newParentId && $0.id != group.id }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    movedGroup.sortOrder = (siblings.last?.sortOrder ?? -1) + 1
                    siblings.append(movedGroup)
                    parent.onReorderGroups?(siblings)
                } else {
                    var siblings = parent.groups
                        .filter { $0.parentGroupId == newParentId && $0.id != group.id }
                        .sorted { $0.sortOrder < $1.sortOrder }

                    var movedGroup = group
                    movedGroup.parentGroupId = newParentId
                    siblings.insert(movedGroup, at: min(childIndex, siblings.count))

                    for (order, var g) in siblings.enumerated() {
                        g.sortOrder = order
                        siblings[order] = g
                    }
                    parent.onReorderGroups?(siblings)
                }
                return true
            }

            if targetItem == nil {
                if childIndex == NSOutlineViewDropOnItemIndex {
                    // Dropped ON root: move as last root group
                    var movedGroup = group
                    movedGroup.parentGroupId = nil
                    var rootGroupSiblings = parent.groups
                        .filter { $0.parentGroupId == nil && $0.id != group.id }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    movedGroup.sortOrder = (rootGroupSiblings.last?.sortOrder ?? -1) + 1
                    rootGroupSiblings.append(movedGroup)
                    parent.onReorderGroups?(rootGroupSiblings)
                } else {
                    var rootGroupSiblings = parent.groups
                        .filter { $0.parentGroupId == nil && $0.id != group.id }
                        .sorted { $0.sortOrder < $1.sortOrder }

                    var movedGroup = group
                    movedGroup.parentGroupId = nil
                    rootGroupSiblings.insert(movedGroup, at: min(childIndex, rootGroupSiblings.count))

                    for (order, var g) in rootGroupSiblings.enumerated() {
                        g.sortOrder = order
                        rootGroupSiblings[order] = g
                    }
                    parent.onReorderGroups?(rootGroupSiblings)
                }
                return true
            }

            return false
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            DesignConstants.RowHeight.comfortable
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            if let outlineGroup = item as? OutlineGroup {
                let cellView: GroupCellView
                if let reused = outlineView.makeView(withIdentifier: .groupCell, owner: self) as? GroupCellView {
                    cellView = reused
                } else {
                    cellView = GroupCellView()
                }
                cellView.configure(group: outlineGroup.group, connectionCount: totalConnectionCount(for: outlineGroup.group.id))
                return cellView
            }
            if let outlineConn = item as? OutlineConnection {
                let cellView: ConnectionCellView
                if let reused = outlineView.makeView(withIdentifier: .connectionCell, owner: self) as? ConnectionCellView {
                    cellView = reused
                } else {
                    cellView = ConnectionCellView()
                }
                cellView.configure(connection: outlineConn.connection)
                return cellView
            }
            return nil
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let outlineGroup = notification.userInfo?["NSObject"] as? OutlineGroup else { return }
            let groupId = outlineGroup.group.id
            if !parent.expandedGroupIds.contains(groupId) {
                parent.onToggleGroup?(groupId)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let outlineGroup = notification.userInfo?["NSObject"] as? OutlineGroup else { return }
            let groupId = outlineGroup.group.id
            if parent.expandedGroupIds.contains(groupId) {
                parent.onToggleGroup?(groupId)
            }
        }

        // MARK: - Double Click

        @objc func handleDoubleClick() {
            guard let outlineView else { return }
            let row = outlineView.clickedRow
            guard row >= 0 else { return }

            let item = outlineView.item(atRow: row)
            if let outlineConn = item as? OutlineConnection {
                parent.onDoubleClickConnection?(outlineConn.connection)
            } else if let outlineGroup = item as? OutlineGroup {
                parent.onToggleGroup?(outlineGroup.group.id)
            }
        }

        private func totalConnectionCount(for groupId: UUID) -> Int {
            let directConns = parent.connections.filter { $0.groupId == groupId }.count
            let childGroupIds = parent.groups.filter { $0.parentGroupId == groupId }.map(\.id)
            let nested = childGroupIds.reduce(0) { $0 + totalConnectionCount(for: $1) }
            return directConns + nested
        }

        // MARK: - Context Menus

        func contextMenu(for outlineGroup: OutlineGroup) -> NSMenu {
            let menu = NSMenu()
            let group = outlineGroup.group

            let newConnItem = NSMenuItem(
                title: String(localized: "New Connection..."),
                action: #selector(contextMenuNewConnection),
                keyEquivalent: ""
            )
            newConnItem.target = self
            newConnItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            menu.addItem(newConnItem)

            let newSubgroupItem = NSMenuItem(
                title: String(localized: "New Subgroup..."),
                action: #selector(contextMenuNewSubgroup(_:)),
                keyEquivalent: ""
            )
            newSubgroupItem.target = self
            newSubgroupItem.representedObject = group.id
            newSubgroupItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            menu.addItem(newSubgroupItem)

            menu.addItem(.separator())

            let editItem = NSMenuItem(
                title: String(localized: "Edit Group..."),
                action: #selector(contextMenuEditGroup(_:)),
                keyEquivalent: ""
            )
            editItem.target = self
            editItem.representedObject = group
            editItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
            menu.addItem(editItem)

            menu.addItem(.separator())

            let deleteItem = NSMenuItem(
                title: String(localized: "Delete Group"),
                action: #selector(contextMenuDeleteGroup(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = group
            deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            deleteItem.setDestructiveStyle()
            menu.addItem(deleteItem)

            return menu
        }

        func contextMenu(for outlineConn: OutlineConnection) -> NSMenu {
            let menu = NSMenu()
            let connection = outlineConn.connection

            let connectItem = NSMenuItem(
                title: String(localized: "Connect"),
                action: #selector(contextMenuConnect(_:)),
                keyEquivalent: ""
            )
            connectItem.target = self
            connectItem.representedObject = connection
            connectItem.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            menu.addItem(connectItem)

            menu.addItem(.separator())

            let editItem = NSMenuItem(
                title: String(localized: "Edit"),
                action: #selector(contextMenuEditConnection(_:)),
                keyEquivalent: ""
            )
            editItem.target = self
            editItem.representedObject = connection
            editItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
            menu.addItem(editItem)

            let duplicateItem = NSMenuItem(
                title: String(localized: "Duplicate"),
                action: #selector(contextMenuDuplicateConnection(_:)),
                keyEquivalent: ""
            )
            duplicateItem.target = self
            duplicateItem.representedObject = connection
            duplicateItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(duplicateItem)

            let copyURLItem = NSMenuItem(
                title: String(localized: "Copy as URL"),
                action: #selector(contextMenuCopyConnectionURL(_:)),
                keyEquivalent: ""
            )
            copyURLItem.target = self
            copyURLItem.representedObject = connection
            copyURLItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            menu.addItem(copyURLItem)

            menu.addItem(.separator())

            // Move to Group submenu
            let moveMenu = NSMenu()

            let noneItem = NSMenuItem(
                title: String(localized: "None"),
                action: #selector(contextMenuMoveToGroup(_:)),
                keyEquivalent: ""
            )
            noneItem.target = self
            noneItem.representedObject = ConnectionMoveInfo(connection: connection, targetGroupId: nil)
            if connection.groupId == nil {
                noneItem.state = .on
            }
            moveMenu.addItem(noneItem)

            moveMenu.addItem(.separator())

            let rootGroups = parent.groups
                .filter { $0.parentGroupId == nil }
                .sorted { $0.sortOrder < $1.sortOrder }

            for group in rootGroups {
                moveMenu.addItem(moveToGroupMenuItem(for: connection, group: group))
            }

            let moveItem = NSMenuItem(title: String(localized: "Move to Group"), action: nil, keyEquivalent: "")
            moveItem.submenu = moveMenu
            moveItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(moveItem)

            menu.addItem(.separator())

            let deleteItem = NSMenuItem(
                title: String(localized: "Delete"),
                action: #selector(contextMenuDeleteConnection(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = connection
            deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            deleteItem.setDestructiveStyle()
            menu.addItem(deleteItem)

            return menu
        }

        func emptySpaceContextMenu() -> NSMenu {
            let menu = NSMenu()

            let newConnItem = NSMenuItem(
                title: String(localized: "New Connection..."),
                action: #selector(contextMenuNewConnection),
                keyEquivalent: ""
            )
            newConnItem.target = self
            newConnItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            menu.addItem(newConnItem)

            let newGroupItem = NSMenuItem(
                title: String(localized: "New Group..."),
                action: #selector(contextMenuNewGroupAtRoot),
                keyEquivalent: ""
            )
            newGroupItem.target = self
            newGroupItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            menu.addItem(newGroupItem)

            return menu
        }

        // MARK: - Multi-Selection Context Menu

        func multiSelectionContextMenu(outlineView: NSOutlineView) -> NSMenu {
            var selectedConnections: [DatabaseConnection] = []
            var selectedGroups: [ConnectionGroup] = []
            for row in outlineView.selectedRowIndexes {
                if let outlineConn = outlineView.item(atRow: row) as? OutlineConnection {
                    selectedConnections.append(outlineConn.connection)
                } else if let outlineGroup = outlineView.item(atRow: row) as? OutlineGroup {
                    selectedGroups.append(outlineGroup.group)
                }
            }

            let menu = NSMenu()

            // Move to Group (only for connections)
            if !selectedConnections.isEmpty, selectedGroups.isEmpty {
                let moveMenu = NSMenu()

                let noneItem = NSMenuItem(
                    title: String(localized: "None"),
                    action: #selector(contextMenuBulkMoveToGroup(_:)),
                    keyEquivalent: ""
                )
                noneItem.target = self
                noneItem.representedObject = BulkMoveInfo(connections: selectedConnections, targetGroupId: nil)
                moveMenu.addItem(noneItem)

                moveMenu.addItem(.separator())

                let rootGroups = parent.groups
                    .filter { $0.parentGroupId == nil }
                    .sorted { $0.sortOrder < $1.sortOrder }
                for group in rootGroups {
                    moveMenu.addItem(bulkMoveToGroupMenuItem(for: selectedConnections, group: group))
                }

                let moveItem = NSMenuItem(
                    title: String(localized: "Move to Group"),
                    action: nil,
                    keyEquivalent: ""
                )
                moveItem.submenu = moveMenu
                moveItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                menu.addItem(moveItem)

                menu.addItem(.separator())
            }

            // Delete
            let totalCount = selectedConnections.count + selectedGroups.count
            let deleteTitle: String
            if !selectedConnections.isEmpty, selectedGroups.isEmpty {
                deleteTitle = String(localized: "Delete \(selectedConnections.count) Connections")
            } else if selectedConnections.isEmpty, !selectedGroups.isEmpty {
                deleteTitle = String(localized: "Delete \(selectedGroups.count) Groups")
            } else {
                deleteTitle = String(localized: "Delete \(totalCount) Items")
            }

            let deleteItem = NSMenuItem(
                title: deleteTitle,
                action: #selector(contextMenuBulkDelete(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = BulkDeleteInfo(connections: selectedConnections, groups: selectedGroups)
            deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            deleteItem.setDestructiveStyle()
            menu.addItem(deleteItem)

            return menu
        }

        // MARK: - Context Menu Actions

        @objc private func contextMenuNewConnection() {
            parent.onNewConnection?()
        }

        @objc private func contextMenuNewSubgroup(_ sender: NSMenuItem) {
            guard let parentId = sender.representedObject as? UUID else { return }
            parent.onNewGroup?(parentId)
        }

        @objc private func contextMenuNewGroupAtRoot() {
            parent.onNewGroup?(nil)
        }

        @objc private func contextMenuEditGroup(_ sender: NSMenuItem) {
            guard let group = sender.representedObject as? ConnectionGroup else { return }
            parent.onEditGroup?(group)
        }

        @objc private func contextMenuDeleteGroup(_ sender: NSMenuItem) {
            guard let group = sender.representedObject as? ConnectionGroup else { return }
            parent.onRequestDelete?([group], [])
        }

        @objc private func contextMenuConnect(_ sender: NSMenuItem) {
            guard let connection = sender.representedObject as? DatabaseConnection else { return }
            parent.onDoubleClickConnection?(connection)
        }

        @objc private func contextMenuEditConnection(_ sender: NSMenuItem) {
            guard let connection = sender.representedObject as? DatabaseConnection else { return }
            parent.onEditConnection?(connection)
        }

        @objc private func contextMenuDuplicateConnection(_ sender: NSMenuItem) {
            guard let connection = sender.representedObject as? DatabaseConnection else { return }
            parent.onDuplicateConnection?(connection)
        }

        @objc private func contextMenuCopyConnectionURL(_ sender: NSMenuItem) {
            guard let connection = sender.representedObject as? DatabaseConnection else { return }
            parent.onCopyConnectionURL?(connection)
        }

        @objc private func contextMenuDeleteConnection(_ sender: NSMenuItem) {
            guard let connection = sender.representedObject as? DatabaseConnection else { return }
            parent.onRequestDelete?([], [connection])
        }

        /// Build an NSMenuItem for a group — if it has children, wrap in a submenu
        private func moveToGroupMenuItem(
            for connection: DatabaseConnection,
            group: ConnectionGroup
        ) -> NSMenuItem {
            let childGroups = parent.groups
                .filter { $0.parentGroupId == group.id }
                .sorted { $0.sortOrder < $1.sortOrder }

            let folderImage = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [
                    group.color.isDefault ? .secondaryLabelColor : NSColor(group.color.color),
                ]))

            if childGroups.isEmpty {
                let item = NSMenuItem(
                    title: group.name,
                    action: #selector(contextMenuMoveToGroup(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = ConnectionMoveInfo(connection: connection, targetGroupId: group.id)
                item.image = folderImage
                if connection.groupId == group.id {
                    item.state = .on
                }
                return item
            } else {
                let submenu = NSMenu()

                // First item: select this group itself
                let selfItem = NSMenuItem(
                    title: group.name,
                    action: #selector(contextMenuMoveToGroup(_:)),
                    keyEquivalent: ""
                )
                selfItem.target = self
                selfItem.representedObject = ConnectionMoveInfo(connection: connection, targetGroupId: group.id)
                selfItem.image = folderImage
                if connection.groupId == group.id {
                    selfItem.state = .on
                }
                submenu.addItem(selfItem)

                submenu.addItem(.separator())

                for child in childGroups {
                    submenu.addItem(moveToGroupMenuItem(for: connection, group: child))
                }

                let item = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
                item.submenu = submenu
                item.image = folderImage
                return item
            }
        }

        @objc private func contextMenuMoveToGroup(_ sender: NSMenuItem) {
            guard let moveInfo = sender.representedObject as? ConnectionMoveInfo else { return }
            parent.onMoveConnectionToGroup?(moveInfo.connection, moveInfo.targetGroupId)
        }

        @objc private func contextMenuBulkDelete(_ sender: NSMenuItem) {
            guard let info = sender.representedObject as? BulkDeleteInfo else { return }
            parent.onRequestDelete?(info.groups, info.connections)
        }

        @objc private func contextMenuBulkMoveToGroup(_ sender: NSMenuItem) {
            guard let info = sender.representedObject as? BulkMoveInfo else { return }
            parent.onMoveConnectionsToGroup?(info.connections, info.targetGroupId)
        }

        private func bulkMoveToGroupMenuItem(
            for connections: [DatabaseConnection],
            group: ConnectionGroup
        ) -> NSMenuItem {
            let childGroups = parent.groups
                .filter { $0.parentGroupId == group.id }
                .sorted { $0.sortOrder < $1.sortOrder }

            let folderImage = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [
                    group.color.isDefault ? .secondaryLabelColor : NSColor(group.color.color),
                ]))

            if childGroups.isEmpty {
                let item = NSMenuItem(
                    title: group.name,
                    action: #selector(contextMenuBulkMoveToGroup(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = BulkMoveInfo(connections: connections, targetGroupId: group.id)
                item.image = folderImage
                return item
            } else {
                let submenu = NSMenu()

                let selfItem = NSMenuItem(
                    title: group.name,
                    action: #selector(contextMenuBulkMoveToGroup(_:)),
                    keyEquivalent: ""
                )
                selfItem.target = self
                selfItem.representedObject = BulkMoveInfo(connections: connections, targetGroupId: group.id)
                selfItem.image = folderImage
                submenu.addItem(selfItem)

                submenu.addItem(.separator())

                for child in childGroups {
                    submenu.addItem(bulkMoveToGroupMenuItem(for: connections, group: child))
                }

                let item = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
                item.submenu = submenu
                item.image = folderImage
                return item
            }
        }
    }
}

// MARK: - ConnectionMoveInfo

/// Helper to pass both connection and target group ID through NSMenuItem.representedObject
private final class ConnectionMoveInfo: NSObject {
    let connection: DatabaseConnection
    let targetGroupId: UUID?

    init(connection: DatabaseConnection, targetGroupId: UUID?) {
        self.connection = connection
        self.targetGroupId = targetGroupId
    }
}

/// Helper for bulk delete via NSMenuItem.representedObject
private final class BulkDeleteInfo: NSObject {
    let connections: [DatabaseConnection]
    let groups: [ConnectionGroup]

    init(connections: [DatabaseConnection], groups: [ConnectionGroup]) {
        self.connections = connections
        self.groups = groups
    }
}

/// Helper for bulk move via NSMenuItem.representedObject
private final class BulkMoveInfo: NSObject {
    let connections: [DatabaseConnection]
    let targetGroupId: UUID?

    init(connections: [DatabaseConnection], targetGroupId: UUID?) {
        self.connections = connections
        self.targetGroupId = targetGroupId
    }
}

// MARK: - NSMenuItem Destructive Style

private extension NSMenuItem {
    func setDestructiveStyle() {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
        ]
        attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }
}
