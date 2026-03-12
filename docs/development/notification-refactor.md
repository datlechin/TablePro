# NotificationCenter Refactor Plan

## Problem

TablePro uses ~40 custom `NotificationCenter` notifications for cross-component communication. This creates:

- **Untraceable coupling** — global broadcasts with no compile-time safety
- **Untyped payloads** — `userInfo` dictionaries with stringly-typed keys
- **Fan-out bugs** — `.refreshData` triggers ALL sidebar instances, not just the target connection
- **Overloaded semantics** — `databaseDidConnect` used both for "connection established" and "please reload sidebar"

## Target Architecture

Replace `NotificationCenter` with proper Swift patterns:

| Pattern                                 | When to Use                                               |
| --------------------------------------- | --------------------------------------------------------- |
| **`@Observable` + SwiftUI observation** | Settings, license status, any model already `@Observable` |
| **Direct method calls**                 | Parent → child, coordinator → owned viewmodel             |
| **`@FocusedValue`**                     | Menu/toolbar → active window's coordinator                |
| **Delegate/closure callbacks**          | 1:1 relationships (SSH tunnel → DatabaseManager)          |
| **Typed event bus (per-connection)**    | Multi-subscriber signals scoped to a connection ID        |

Keep `NotificationCenter` only for: AppKit → SwiftUI bridges where no shared reference exists (e.g., `NSApplicationDelegate` → SwiftUI scene).

---

## Phase 1: Remove Dead Notifications

**Status:** Done (PR [#281](https://github.com/datlechin/TablePro/pull/281))

Removed 11 notifications that had no sender OR no subscriber. Pure cleanup, zero risk.

### Removed (defined + observed, never posted):

- [x] `formatQueryRequested` — subscriber in `QueryEditorView`, no sender
- [x] `sendAIPrompt` — subscriber in `AIChatPanelView`, no sender
- [x] `reconnectDatabase` — subscriber in `MainContentCommandActions`, no sender
- [x] `refreshAll` — subscribers in `SidebarViewModel` + `MainContentCommandActions`, no sender
- [x] `connectionHealthStateChanged` — defined in `AppNotifications.swift`, no sender or subscriber
- [x] `applyAllFilters` — subscriber in `MainContentCommandActions`, no sender
- [x] `duplicateFilter` — subscriber in `MainContentCommandActions`, no sender
- [x] `removeFilter` — subscriber in `MainContentCommandActions`, no sender
- [x] `deselectConnection` — subscriber in `ContentView`, no sender

### Removed (posted, never observed):

- [x] `licenseStatusDidChange` — posted by `LicenseManager` (which is `@Observable`, consumers already use observation)
- [x] `pluginStateDidChange` — posted by `PluginManager`, no subscriber

Also removed cascading dead code: `handleRefreshAll`, `handleReconnect`, filter broadcast handlers, `DiscardAction.refreshAll` enum case. Net -139 lines across 12 files.

---

## Phase 2: Replace Settings Notifications with `@Observable`

**Status:** Done (PR [#282](https://github.com/datlechin/TablePro/pull/282))

Removed 7 notification names and `SettingsChangeInfo` infrastructure. Replaced Combine subscriber with direct call, converted 2 SwiftUI subscribers to `@Observable` observation.

### Removed (dead — zero subscribers):

- [x] `appearanceSettingsDidChange`
- [x] `generalSettingsDidChange`
- [x] `tabSettingsDidChange`
- [x] `keyboardSettingsDidChange`
- [x] `aiSettingsDidChange`
- [x] `settingsDidChange` (generic catch-all)

### Converted:

- [x] `historySettingsDidChange` — replaced Combine subscriber in `QueryHistoryManager` with direct `applySettingsChange()` call from `AppSettingsManager`
- [x] `editorSettingsDidChange` (SwiftUI) — `SQLEditorView` uses `.onChange(of: AppSettingsManager.shared.editor)`, `QueryEditorView` reads `@Observable` directly in `body`

### Kept (AppKit bridges):

- [x] `dataGridSettingsDidChange` — `DataGridView` (AppKit), `DataGridCellFactory` (AppKit)
- [x] `editorSettingsDidChange` — `SQLEditorCoordinator` (AppKit)
- [x] `accessibilityTextSizeDidChange` — system event bridge

Also removed: `SettingsChangeInfo` struct, `Notification.settingsChangeInfo` extension, `import Combine` from `QueryHistoryManager`. Net -120 lines.

---

## Phase 3: Replace Data Refresh with Direct Coordinator-to-Sidebar Calls

**Status:** Done (PR [#283](https://github.com/datlechin/TablePro/pull/283))

Gave the coordinator a direct `weak var sidebarViewModel` reference, replacing 12 global broadcasts with scoped `reloadSidebar()` calls. Fixed `.databaseDidConnect` abuse in save/discard paths. Sidebar reloads are now per-window instead of global.

### What changed:

- [x] `MainContentCoordinator` — added `weak var sidebarViewModel` + `reloadSidebar()` method
- [x] `SidebarView` — accepts `coordinator` parameter, wires `coordinator.sidebarViewModel = viewModel` on appear
- [x] `ContentView` — passes `coordinator: sessionState.coordinator` to `SidebarView`
- [x] `+Navigation.swift` — replaced all 10 `.refreshData` posts with `reloadSidebar()`
- [x] `+SaveChanges.swift` — replaced `.databaseDidConnect` abuse with `reloadSidebar()`
- [x] `+Discard.swift` — replaced `.databaseDidConnect` abuse with `reloadSidebar()`
- [x] `SidebarViewModel` — removed `Publishers.Merge` subscription for `.databaseDidConnect`/`.refreshData`
- [x] `MainContentCommandActions` — chained `coordinator?.reloadSidebar()` into `handleRefreshData()` and `handleDatabaseDidConnect()` so menu/toolbar/import/DatabaseManager signals still reach the sidebar

### What's kept:

- `.refreshData` — still posted by menu (Cmd+R), toolbar, `ImportDialog`, `DatabaseManager.applySchemaChanges()`. Flows through `MainContentCommandActions.handleRefreshData()` → chains `reloadSidebar()`.
- `.databaseDidConnect` — still posted by `DatabaseManager` (legitimate). Flows through `MainContentCommandActions.handleDatabaseDidConnect()` → chains `reloadSidebar()`. `AppDelegate` subscribers kept for file queue draining.

---

## Phase 4: Replace Sidebar Action Notifications with Direct Calls

**Status:** Done (PR [#286](https://github.com/datlechin/TablePro/pull/286))

Replaced 9 sidebar action notifications with direct coordinator calls and `@FocusedValue` routing. Context menu actions call coordinator directly. Menu bar uses `actions?.copyTableNames()` and `actions?.truncateTables()` via `@FocusedValue`.

- [x] `copyTableNames` — menu → `actions?.copyTableNames()` → `coordinator.sidebarViewModel.copySelectedTableNames()`
- [x] `truncateTables` — menu → `actions?.truncateTables()` → `coordinator.sidebarViewModel.batchToggleTruncate()`
- [x] `clearSelection` — dead (no sender), removed both subscribers
- [x] `showAllTables` — `SidebarView` calls `coordinator?.showAllTablesMetadata()` directly
- [x] `showTableStructure` — context menu → `coordinator?.openTableTab(_, showStructure:)`
- [x] `editViewDefinition` — context menu → `coordinator?.editViewDefinition(_:)`
- [x] `createView` — context menu → `coordinator?.createView()`
- [x] `exportTables` — context menu → `coordinator?.openExportDialog()`
- [x] `importTables` — context menu → `coordinator?.openImportDialog()`

Also extracted `createView()`, `editViewDefinition(_:)`, `openExportDialog()`, `openImportDialog()` from `MainContentCommandActions` into `MainContentCoordinator+SidebarActions.swift`. Removed all notification infrastructure from `SidebarViewModel` (`import Combine`, `cancellables`, `setupNotifications()`).

---

## Phase 5: Replace Structure View Notifications with Coordinator Pattern

**Status:** Done

Created `StructureViewActionHandler` class with closure properties for each action. `TableStructureView` wires closures in `.onAppear` and registers handler with coordinator. Senders call `coordinator.structureActions?.method?()` instead of posting notifications.

### Notifications replaced:

- [x] `copySelectedRows` (structure path) — now `structureActions?.copyRows?()`
- [x] `pasteRows` (structure path) — now `structureActions?.pasteRows?()`
- [x] `undoChange` — removed notification name, now `structureActions?.undo?()`
- [x] `redoChange` — removed notification name, now `structureActions?.redo?()`
- [x] `saveStructureChanges` — removed notification name, now `structureActions?.saveChanges?()`
- [x] `previewStructureSQL` — removed notification name, now `structureActions?.previewSQL?()`

### Files changed:

- **New:** `Views/Structure/StructureViewActionHandler.swift` — action handler class
- **Modified:** `MainContentCoordinator.swift` — added `weak var structureActions`
- **Modified:** `TableStructureView.swift` — wire closures on appear, removed 6 `.onReceive` handlers
- **Modified:** `MainEditorContentView.swift` — pass coordinator to `TableStructureView`
- **Modified:** `MainContentCommandActions.swift` — 6 notification posts → direct calls
- **Modified:** `MainContentCoordinator+SQLPreview.swift` — notification post → direct call
- **Modified:** `TableProApp.swift` — removed 4 notification name definitions

---

## Phase 6: Replace Editor/AI Notifications with Direct References

**Status:** Done

Replaced 7 notifications with direct calls. Editor notifications use `@FocusedValue(\.commandActions)` or direct coordinator methods. AI notifications use `coordinator.aiViewModel` reference with typed action methods on `AIChatViewModel`. Context menu AI actions use closure chains through `SQLEditorCoordinator`.

### Editor notifications replaced:

- [x] `loadQueryIntoEditor` — `@FocusedValue` in `HistoryPanelView`, direct call in `QuickSwitcher`
- [x] `insertQueryFromAI` — `@FocusedValue` in `AIChatCodeBlockView`
- [x] `newQueryTab` — `@FocusedValue` in `HistoryPanelView` → `actions?.newTab(initialQuery:)`
- [x] `explainQuery` — closure `onExplain` on `QueryEditorView`

### AI notifications replaced:

- [x] `aiFixError` — `coordinator.showAIChatPanel()` + `aiViewModel?.handleFixError()`
- [x] `aiExplainSelection` — closure chain: `AIEditorContextMenu` → `SQLEditorCoordinator` → `SQLEditorView` → `QueryEditorView` → `MainEditorContentView` → coordinator
- [x] `aiOptimizeSelection` — same closure chain as above

### Files changed:

- **Modified:** `MainContentCoordinator.swift` — added `loadQueryIntoEditor()`, `insertQueryFromAI()`, `aiViewModel`, `rightPanelState`, `showAIChatPanel()`
- **Modified:** `MainContentCommandActions.swift` — added forwarding methods, removed 4 notification observers + 2 handlers
- **Modified:** `HistoryPanelView.swift` — `@FocusedValue` replaces 2 notification posts
- **Modified:** `MainContentCoordinator+QuickSwitcher.swift` — direct coordinator call
- **Modified:** `AIChatCodeBlockView.swift` — `@FocusedValue` replaces notification post
- **Modified:** `QueryEditorView.swift` — added `onExplain`, `onAIExplain`, `onAIOptimize` closures
- **Modified:** `MainEditorContentView.swift` — wired all new closures
- **Modified:** `AIChatViewModel.swift` — added `handleFixError()`, `handleExplainSelection()`, `handleOptimizeSelection()`
- **Modified:** `MainContentView.swift` — wired `coordinator.aiViewModel` and `coordinator.rightPanelState`
- **Modified:** `AIEditorContextMenu.swift` — closures replace notification posts
- **Modified:** `SQLEditorCoordinator.swift` — added `onAIExplain`, `onAIOptimize` closures
- **Modified:** `SQLEditorView.swift` — passes AI closures to coordinator
- **Modified:** `AIChatPanelView.swift` — removed 3 `.onReceive` handlers and moved helpers to viewmodel
- **Modified:** `AppNotifications.swift` — removed 5 notification definitions
- **Modified:** `TableProApp.swift` — removed 2 notification definitions

---

## Phase 7: Replace Window Lifecycle Notifications

**Status:** Done

Replaced 2 singleton-to-singleton notifications with direct method calls. `SSHTunnelManager` calls `DatabaseManager.shared.handleSSHTunnelDied(connectionId:)` directly. `WindowLifecycleMonitor` calls `DatabaseManager.shared.disconnectSession(_:)` directly. Removed notification observers and cleanup from `DatabaseManager`.

### Replaced:

- [x] `lastWindowDidClose` — `WindowLifecycleMonitor` calls `DatabaseManager.shared.disconnectSession(_:)` directly
- [x] `sshTunnelDied` — `SSHTunnelManager` calls `DatabaseManager.shared.handleSSHTunnelDied(connectionId:)` directly

### Kept (cross-scene broadcasts, no shared reference):

- `connectionUpdated` — `ConnectionFormView`/`AppDelegate` → `WelcomeWindowView`
- `newConnection` — `TableProApp` → `WelcomeWindowView`/`ContentView`
- `databaseDidConnect` — `DatabaseManager` → `MainContentCommandActions`

---

## Phase 8: Replace Deep-Link Notifications

**Status:** Not started

- [ ] `openSQLFiles` — `AppDelegate` → `MainContentCommandActions`. Keep notification (legitimate AppKit → SwiftUI bridge).
- [ ] `switchSchemaFromURL` — `AppDelegate` → coordinator. Keep or use a coordinator lookup by connectionId.
- [ ] `applyURLFilter` — `AppDelegate` → coordinator. Same.

---

## Priority Order

1. **Phase 1** (dead code removal) — zero risk, immediate cleanup
2. **Phase 3** (data refresh scoping) — fixes the actual sidebar bug, biggest architectural win
3. **Phase 4** (sidebar actions via @FocusedValue) — clean menu routing
4. **Phase 5** (structure view) — removes the most confusing notification routing
5. **Phase 6** (editor/AI) — cleaner inter-panel communication
6. **Phase 2** (settings) — partial, only SwiftUI consumers
7. **Phase 7** (window lifecycle) — lower priority, partially legitimate
8. **Phase 8** (deep-link) — mostly keep as-is

## Metrics

| Metric                                       | Before | Current | Target                                           |
| -------------------------------------------- | ------ | ------- | ------------------------------------------------ |
| Custom notification names                    | 62     | ~33     | ~15 (AppKit bridges + settings for AppKit views) |
| Dead notifications                           | 11     | 0       | 0                                                |
| Global broadcasts without connection scoping | 3      | 1       | 0                                                |
| `userInfo` dictionary payloads               | ~8     | ~7      | 0 (typed APIs)                                   |
