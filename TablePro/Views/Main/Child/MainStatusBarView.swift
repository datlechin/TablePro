//
//  MainStatusBarView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 24/12/25.
//

import SwiftUI

/// Status bar at the bottom of the results section
struct MainStatusBarView: View {
    let tab: QueryTab?
    let filterStateManager: FilterStateManager
    let selectedRowIndices: Set<Int>
    @Binding var showStructure: Bool

    // Pagination callbacks
    let onFirstPage: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLastPage: () -> Void
    let onLimitChange: (Int) -> Void
    let onOffsetChange: (Int) -> Void
    let onPaginationGo: () -> Void

    var body: some View {
        HStack {
            // Left: Data/Structure toggle for table tabs
            if let tab = tab, tab.tabType == .table, tab.tableName != nil {
                Picker("", selection: $showStructure) {
                    Label("Data", systemImage: "tablecells").tag(false)
                    Label("Structure", systemImage: "list.bullet.rectangle").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .controlSize(.small)
                .offset(x: -26)
            }

            Spacer()

            Spacer()

            // Center: Row info (selection or pagination summary)
            if let tab = tab, !tab.resultRows.isEmpty {
                Text(rowInfoText(for: tab))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Right: Filters toggle and Pagination controls
            HStack(spacing: 8) {
                // Filters toggle button
                if let tab = tab, tab.tabType == .table, tab.tableName != nil {
                    Toggle(isOn: Binding(
                        get: { filterStateManager.isVisible },
                        set: { _ in filterStateManager.toggle() }
                    )) {
                        HStack(spacing: 4) {
                            Image(systemName: filterStateManager.hasAppliedFilters
                                    ? "line.3.horizontal.decrease.circle.fill"
                                    : "line.3.horizontal.decrease.circle")
                            Text("Filters")
                            if filterStateManager.hasAppliedFilters {
                                Text("(\(filterStateManager.appliedFilters.count))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Toggle Filters (Cmd+F)")
                }

                // Pagination controls for table tabs
                if let tab = tab, tab.tabType == .table, tab.tableName != nil,
                   let total = tab.pagination.totalRowCount, total > 0 {
                    PaginationControlsView(
                        pagination: tab.pagination,
                        onFirst: onFirstPage,
                        onPrevious: onPreviousPage,
                        onNext: onNextPage,
                        onLast: onLastPage,
                        onLimitChange: onLimitChange,
                        onOffsetChange: onOffsetChange,
                        onGo: onPaginationGo
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Generate row info text based on selection and pagination state
    private func rowInfoText(for tab: QueryTab) -> String {
        let loadedCount = tab.resultRows.count
        let selectedCount = selectedRowIndices.count
        let pagination = tab.pagination
        let total = pagination.totalRowCount

        if selectedCount > 0 {
            // Selection mode: "5 of 200 rows selected"
            if selectedCount == loadedCount {
                return "All \(loadedCount) rows selected"
            } else {
                return "\(selectedCount) of \(loadedCount) rows selected"
            }
        } else if let total = total, total > 0 {
            // Pagination mode: "201-400 of 5,000 rows"
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let formattedTotal = formatter.string(from: NSNumber(value: total)) ?? "\(total)"

            return "\(pagination.rangeStart)-\(pagination.rangeEnd) of \(formattedTotal) rows"
        } else if loadedCount > 0 {
            // Simple mode: "100 rows"
            return "\(loadedCount) rows"
        } else {
            return "No rows"
        }
    }
}
