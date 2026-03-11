//
//  QuickSwitcherView.swift
//  TablePro
//
//  Quick switcher sheet for searching and opening database objects.
//  Presented as a native SwiftUI .sheet() via the ActiveSheet pattern.
//

import SwiftUI

// MARK: - Sheet

/// Native SwiftUI sheet for the quick switcher, matching the project's ActiveSheet pattern.
struct QuickSwitcherSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    let schemaProvider: SQLSchemaProvider
    let connectionId: UUID
    let databaseType: DatabaseType
    let onSelect: (QuickSwitcherItem) -> Void

    @State private var viewModel = QuickSwitcherViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("Quick Switcher")
                .font(.system(size: DesignConstants.FontSize.body, weight: .semibold))
                .padding(.vertical, 12)

            Divider()

            // Search toolbar
            searchToolbar

            Divider()

            // Content
            if viewModel.isLoading {
                loadingView
            } else if viewModel.filteredItems.isEmpty {
                emptyState
            } else {
                itemList
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 460, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.loadItems(
                schemaProvider: schemaProvider,
                connectionId: connectionId,
                databaseType: databaseType
            )
        }
        .onExitCommand { dismiss() }
        .onKeyPress(.return) {
            openSelectedItem()
            return .handled
        }
        .onKeyPress(.upArrow) {
            Task { @MainActor in viewModel.moveUp() }
            return .handled
        }
        .onKeyPress(.downArrow) {
            Task { @MainActor in viewModel.moveDown() }
            return .handled
        }
    }

    // MARK: - Search Toolbar

    private var searchToolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DesignConstants.FontSize.body))
                .foregroundStyle(.tertiary)

            TextField("Search tables, views, databases...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: DesignConstants.FontSize.body))

            if !viewModel.searchText.isEmpty {
                Button(action: { viewModel.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Item List

    private var itemList: some View {
        ScrollViewReader { proxy in
            List(selection: $viewModel.selectedItemId) {
                if viewModel.searchText.isEmpty {
                    // Grouped by kind when not searching
                    ForEach(viewModel.groupedItems, id: \.kind) { group in
                        Section {
                            ForEach(group.items) { item in
                                itemRow(item)
                            }
                        } header: {
                            Text(sectionTitle(for: group.kind))
                                .font(.system(size: DesignConstants.FontSize.caption, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    // Flat ranked list when searching
                    ForEach(viewModel.filteredItems) { item in
                        itemRow(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: viewModel.selectedItemId) { _, newValue in
                if let itemId = newValue {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(itemId, anchor: .center)
                    }
                }
            }
        }
    }

    private func itemRow(_ item: QuickSwitcherItem) -> some View {
        let isSelected = item.id == viewModel.selectedItemId

        return HStack(spacing: 10) {
            Image(systemName: item.iconName)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? .white : .secondary)

            Text(item.name)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.kindLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.white.opacity(0.15) : Color(nsColor: .quaternaryLabelColor))
                )
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .listRowBackground(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
                .padding(.horizontal, 4)
        )
        .listRowInsets(DesignConstants.swiftUIListRowInsets)
        .listRowSeparator(.hidden)
        .id(item.id)
        .tag(item.id)
        .overlay(
            DoubleClickOverlay {
                viewModel.selectedItemId = item.id
                openSelectedItem()
            }
        )
    }

    // MARK: - Empty States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading...")
                .font(.system(size: DesignConstants.FontSize.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DesignConstants.IconSize.extraLarge))
                .foregroundStyle(.secondary)

            if viewModel.searchText.isEmpty {
                Text("No objects found")
                    .font(.system(size: DesignConstants.FontSize.body, weight: .medium))
            } else {
                Text("No matching objects")
                    .font(.system(size: DesignConstants.FontSize.body, weight: .medium))

                Text("No objects match \"\(viewModel.searchText)\"")
                    .font(.system(size: DesignConstants.FontSize.small))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }

            Spacer()

            Button("Open") {
                openSelectedItem()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedItem == nil)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func sectionTitle(for kind: QuickSwitcherItemKind) -> String {
        switch kind {
        case .table: return "TABLES"
        case .view: return "VIEWS"
        case .systemTable: return "SYSTEM TABLES"
        case .database: return "DATABASES"
        case .schema: return "SCHEMAS"
        case .queryHistory: return "RECENT QUERIES"
        }
    }

    private func openSelectedItem() {
        guard let item = viewModel.selectedItem else { return }
        onSelect(item)
        dismiss()
    }
}

// MARK: - DoubleClickOverlay

/// NSViewRepresentable that detects double-clicks without interfering with native List selection
private struct DoubleClickOverlay: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughDoubleClickView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PassThroughDoubleClickView)?.onDoubleClick = onDoubleClick
    }
}

private class PassThroughDoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        }
        super.mouseDown(with: event)
    }
}
