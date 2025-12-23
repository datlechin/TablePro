//
//  QueryTabBar.swift
//  OpenTable
//
//  Tab bar for multiple query tabs
//

import SwiftUI

/// Tab bar showing all open query tabs
struct QueryTabBar: View {
    @ObservedObject var tabManager: QueryTabManager

    var body: some View {
        HStack(spacing: 0) {
            // Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(tabManager.tabs) { tab in
                        TabItem(
                            tab: tab,
                            isSelected: tabManager.selectedTabId == tab.id,
                            onSelect: { tabManager.selectTab(tab) },
                            onClose: { tabManager.closeTab(tab) }
                        )
                        .contextMenu {
                            tabContextMenu(for: tab)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            // Add tab button
            Button(action: { tabManager.addTab() }) {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("New Query Tab (⌘T)")
            .keyboardShortcut(KeyboardShortcuts.newTab)
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func tabContextMenu(for tab: QueryTab) -> some View {
        Button("Duplicate Tab") {
            tabManager.duplicateTab(tab)
        }

        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
            tabManager.togglePin(tab)
        }

        Divider()

        Button("Close Tab") {
            tabManager.closeTab(tab)
        }

        Button("Close Other Tabs") {
            let pinnedTabs = tabManager.tabs.filter { $0.isPinned || $0.id == tab.id }
            tabManager.tabs = pinnedTabs.isEmpty ? [tab] : pinnedTabs
            tabManager.selectedTabId = tab.id
        }
    }
}

// MARK: - Tab Item

struct TabItem: View {
    let tab: QueryTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Pin indicator
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            // Executing indicator
            if tab.isExecuting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                // Tab type icon
                Image(systemName: tab.tabType == .table ? "tablecells" : "doc.text")
                    .font(.caption2)
                    .foregroundStyle(tab.tabType == .table ? .blue : .secondary)
            }

            // Title
            Text(tab.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            // Close button
            if isHovering && !tab.isPinned {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { _ in
                onSelect()
            }
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

#Preview {
    QueryTabBar(tabManager: QueryTabManager())
        .frame(width: 600)
}
