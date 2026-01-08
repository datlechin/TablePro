//
//  QueryPreviewViewController.swift
//  TablePro
//
//  Right pane controller for displaying query preview with syntax highlighting
//

import AppKit

/// Displays query preview with syntax highlighting and metadata
final class QueryPreviewViewController: NSViewController {
    // MARK: - State

    private enum PreviewMode {
        case history(QueryHistoryEntry)
        case bookmark(QueryBookmark)
        case empty
    }

    private var previewMode: PreviewMode = .empty {
        didSet {
            updateUI()
        }
    }

    // MARK: - UI Components

    private let containerStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // Query text view
    private let queryScrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = true
        scroll.backgroundColor = SQLEditorTheme.background
        return scroll
    }()

    private lazy var queryTextView: NSTextView = {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = SQLEditorTheme.font
        textView.textColor = SQLEditorTheme.text
        textView.backgroundColor = SQLEditorTheme.background
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return textView
    }()

    private var syntaxHighlighter: SyntaxHighlighter?

    // Metadata footer
    private let metadataContainer: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let metadataStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        return stack
    }()

    private let primaryMetadataLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: DesignConstants.FontSize.small)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let secondaryMetadataLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: DesignConstants.FontSize.small)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    // Action buttons
    private let buttonContainer: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var copyButton: NSButton = {
        let button = NSButton(title: "Copy Query", target: self, action: #selector(copyQuery))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var loadButton: NSButton = {
        let button = NSButton(title: "Load in Editor", target: self, action: #selector(loadInEditor))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        button.keyEquivalent = "\r"
        return button
    }()

    // Empty state
    private lazy var emptyStateView: NSView = {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Select a query")
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .tertiaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 48),
            imageView.heightAnchor.constraint(equalToConstant: 48)
        ])

        let titleLabel = NSTextField(labelWithString: "Select a Query")
        titleLabel.font = .systemFont(ofSize: DesignConstants.FontSize.title3, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(labelWithString: "Choose a query from the list\nto see its full content here.")
        subtitleLabel.font = .systemFont(ofSize: DesignConstants.FontSize.medium)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2

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

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupSyntaxHighlighter()
        updateUI()
    }

    // MARK: - Setup

    private func setupUI() {
        // Query scroll view
        queryScrollView.documentView = queryTextView
        view.addSubview(queryScrollView)

        // Divider above metadata
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(divider)

        // Metadata container
        metadataStack.addArrangedSubview(primaryMetadataLabel)
        metadataStack.addArrangedSubview(secondaryMetadataLabel)
        metadataContainer.addSubview(metadataStack)
        view.addSubview(metadataContainer)

        // Divider above buttons
        let buttonDivider = NSBox()
        buttonDivider.boxType = .separator
        buttonDivider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonDivider)

        // Button container
        buttonContainer.addSubview(copyButton)
        buttonContainer.addSubview(loadButton)
        view.addSubview(buttonContainer)

        // Empty state
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            // Query scroll view
            queryScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            queryScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            queryScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Divider
            divider.topAnchor.constraint(equalTo: queryScrollView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Metadata container
            metadataContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            metadataContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metadataContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            metadataStack.topAnchor.constraint(equalTo: metadataContainer.topAnchor),
            metadataStack.leadingAnchor.constraint(equalTo: metadataContainer.leadingAnchor),
            metadataStack.trailingAnchor.constraint(equalTo: metadataContainer.trailingAnchor),
            metadataStack.bottomAnchor.constraint(equalTo: metadataContainer.bottomAnchor),

            // Button divider
            buttonDivider.topAnchor.constraint(equalTo: metadataContainer.bottomAnchor),
            buttonDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            buttonDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Button container
            buttonContainer.topAnchor.constraint(equalTo: buttonDivider.bottomAnchor),
            buttonContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            buttonContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            buttonContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            buttonContainer.heightAnchor.constraint(equalToConstant: 44),

            // Buttons inside container
            copyButton.leadingAnchor.constraint(equalTo: buttonContainer.leadingAnchor, constant: 12),
            copyButton.centerYAnchor.constraint(equalTo: buttonContainer.centerYAnchor),

            loadButton.trailingAnchor.constraint(equalTo: buttonContainer.trailingAnchor, constant: -12),
            loadButton.centerYAnchor.constraint(equalTo: buttonContainer.centerYAnchor),

            // Empty state
            emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupSyntaxHighlighter() {
        guard let textStorage = queryTextView.textStorage else { return }
        syntaxHighlighter = SyntaxHighlighter(textStorage: textStorage)
    }

    // MARK: - Public API

    func showHistoryEntry(_ entry: QueryHistoryEntry) {
        previewMode = .history(entry)
    }

    func showBookmark(_ bookmark: QueryBookmark) {
        previewMode = .bookmark(bookmark)
    }

    func clearPreview() {
        previewMode = .empty
    }

    // MARK: - UI Updates

    private func updateUI() {
        switch previewMode {
        case .empty:
            showEmptyState()

        case .history(let entry):
            showQueryPreview(
                query: entry.query,
                primaryMetadata: buildHistoryPrimaryMetadata(entry),
                secondaryMetadata: buildHistorySecondaryMetadata(entry)
            )

        case .bookmark(let bookmark):
            showQueryPreview(
                query: bookmark.query,
                primaryMetadata: buildBookmarkPrimaryMetadata(bookmark),
                secondaryMetadata: buildBookmarkSecondaryMetadata(bookmark)
            )
        }
    }

    private func showEmptyState() {
        emptyStateView.isHidden = false
        queryScrollView.isHidden = true
        metadataContainer.isHidden = true
        buttonContainer.isHidden = true

        // Hide dividers by finding them
        for subview in view.subviews where subview is NSBox {
            subview.isHidden = true
        }
    }

    private func showQueryPreview(query: String, primaryMetadata: String, secondaryMetadata: String) {
        emptyStateView.isHidden = true
        queryScrollView.isHidden = false
        metadataContainer.isHidden = false
        buttonContainer.isHidden = false

        // Show dividers
        for subview in view.subviews where subview is NSBox {
            subview.isHidden = false
        }

        // Set query text
        queryTextView.string = query

        // Apply syntax highlighting
        syntaxHighlighter?.highlightFullDocument()

        // Scroll to top
        queryTextView.scrollToBeginningOfDocument(nil)

        // Update metadata
        primaryMetadataLabel.stringValue = primaryMetadata
        secondaryMetadataLabel.stringValue = secondaryMetadata
    }

    // MARK: - Metadata Builders

    private func buildHistoryPrimaryMetadata(_ entry: QueryHistoryEntry) -> String {
        var parts: [String] = []
        parts.append("Database: \(entry.databaseName)")
        parts.append(entry.formattedExecutionTime)

        if entry.rowCount >= 0 {
            parts.append(entry.formattedRowCount)
        }

        return parts.joined(separator: "  |  ")
    }

    private func buildHistorySecondaryMetadata(_ entry: QueryHistoryEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var text = "Executed: \(formatter.string(from: entry.executedAt))"

        if !entry.wasSuccessful, let error = entry.errorMessage {
            text += "\nError: \(error)"
        }

        return text
    }

    private func buildBookmarkPrimaryMetadata(_ bookmark: QueryBookmark) -> String {
        var parts: [String] = []
        parts.append("Name: \(bookmark.name)")

        if bookmark.hasTags {
            parts.append("Tags: \(bookmark.formattedTags)")
        }

        return parts.joined(separator: "  |  ")
    }

    private func buildBookmarkSecondaryMetadata(_ bookmark: QueryBookmark) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none

        var text = "Created: \(dateFormatter.string(from: bookmark.createdAt))"

        if let lastUsed = bookmark.lastUsedAt {
            text += "  |  Last used: \(dateFormatter.string(from: lastUsed))"
        }

        if let notes = bookmark.notes, !notes.isEmpty {
            text += "\nNotes: \(notes)"
        }

        return text
    }

    // MARK: - Actions

    @objc private func copyQuery() {
        let query = getCurrentQuery()
        guard !query.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(query, forType: .string)

        // Visual feedback - briefly change button title
        let originalTitle = copyButton.title
        copyButton.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.copyButton.title = originalTitle
        }
    }

    @objc private func loadInEditor() {
        let query = getCurrentQuery()
        guard !query.isEmpty else { return }

        NotificationCenter.default.post(
            name: .loadQueryIntoEditor,
            object: nil,
            userInfo: ["query": query]
        )

        // Mark bookmark as used if applicable
        if case .bookmark(let bookmark) = previewMode {
            QueryHistoryManager.shared.markBookmarkUsed(id: bookmark.id)
        }
    }

    private func getCurrentQuery() -> String {
        switch previewMode {
        case .history(let entry):
            return entry.query
        case .bookmark(let bookmark):
            return bookmark.query
        case .empty:
            return ""
        }
    }
}
