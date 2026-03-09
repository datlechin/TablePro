# Memory Audit — TablePro

**Date:** 2026-03-09
**Baseline measurements** (MySQL connection, default page size 1,000 rows):

| State | Memory | Delta |
|-------|--------|-------|
| Welcome screen | ~40 MB | — |
| Connect to MySQL | ~150 MB | +110 MB |
| First table tab | ~160 MB | +10 MB |
| Second table tab | ~250 MB | +90 MB |
| Third table tab | ~380 MB | +130 MB |

---

## Root Causes (ranked by impact)

### 1. Three database driver instances per connection

**Impact: ~90–150 MB fixed cost on connect**
**Files:** `Core/Database/DatabaseManager.swift` lines 159, 223, 484

Every connection creates three separate C-level driver instances:
- **Main driver** (line 159) — user queries
- **Metadata driver** (line 223) — background FK/column fetches
- **Ping driver** (line 484) — 30s health check

Each carries its own C library state (libmariadb internal buffers, TLS context, TCP socket). For MySQL this is ~30–50 MB per connection × 3 = the bulk of the +110 MB jump on connect.

**Fix options:**
- [ ] Multiplex metadata queries on the main driver when idle (eliminates 1 driver)
- [x] Use a lightweight ping mechanism (e.g., TCP keepalive or `mysql_ping` on main driver with a mutex) instead of a dedicated ping driver — **Done**: removed dedicated `pingDrivers` dict, health checks now use main driver
- [x] Lazy-create the metadata driver only when needed, release after use — **Done**: `ensureMetadataDriver(for:)` creates on first Phase 2 request; deduplicates in-flight creation tasks

---

### 2. Triple-copy of row data per tab

**Impact: 3–10 MB duplicated per tab (more for wide/text-heavy tables)**
**Files:**
- `Models/Query/QueryTab.swift` — `RowBuffer.rows` (canonical store)
- `Models/Query/RowProvider.swift` lines 65–97 — `InMemoryRowProvider.sourceRows` (second copy)
- `Views/Main/Child/MainEditorContentView.swift` lines 332–342 — `makeRowProvider()` creates the provider

**How it happens:**
1. `RowBuffer.rows: [QueryResultRow]` holds the query result (copy 1)
2. `makeRowProvider()` passes rows into `InMemoryRowProvider(rows:)`, which stores them as `sourceRows` (copy 2 — CoW breaks on first edit)
3. `InMemoryRowProvider.rowCache: [Int: TableRowData]` materializes up to 5,000 `TableRowData` objects, each wrapping another `[String?]` (copy 3)

For sorted tabs, `sortedRows(for:)` at `MainEditorContentView.swift:406` calls `.map { tab.resultRows[$0] }`, materializing yet another full `[QueryResultRow]` array before handing it to the provider.

**Fix options:**
- [x] Make `InMemoryRowProvider` reference `RowBuffer` directly instead of copying rows — **Done**: primary init takes `rowBuffer: RowBuffer` + optional `sortIndices: [Int]?`; convenience init wraps rows for backward compat
- [ ] Replace `rowCache` with index-based access into `sourceRows` (avoid `TableRowData` wrapper objects)
- [x] For sorted tabs, store only the index permutation and let the provider apply it lazily — **Done**: `sortIndicesForTab(_:)` returns `[Int]?` permutation; `InMemoryRowProvider` resolves display→source indices via `resolveSourceIndex()`

---

### 3. Tab eviction does not work for native window-tabs

**Impact: All inactive tabs retain full row data indefinitely**
**Files:**
- `Views/Main/Extensions/MainContentCoordinator+TabSwitch.swift` lines 109–130

`evictInactiveTabs(excluding:)` only fires when `tabManager.tabs.count > 2`. Since each native macOS tab is a separate `NSWindow` with its own `MainContentCoordinator` and `QueryTabManager` containing exactly 1 tab, the condition `tabs.count > 2` is never true for table tabs. Eviction never triggers.

Even when eviction does trigger (multiple query sub-tabs within one window), `RowBuffer.evict()` clears `rows = []` but the `InMemoryRowProvider` in `MainEditorContentView.tabRowProviders` still holds its own `sourceRows` copy — it is not cleared.

**Fix options:**
- [ ] Implement cross-window eviction via a global `TabMemoryManager` that tracks all open tabs across windows
- [x] When `RowBuffer.evict()` fires, also notify/invalidate the corresponding `InMemoryRowProvider` — **Done**: `rowProvider(for:)` checks `isEvicted` and drops cached provider
- [x] Add `NSWindow.didResignKeyNotification` observer to trigger proactive eviction — **Done**: `MainContentView` schedules 5s delayed eviction via `evictInactiveRowData()` on window resign

---

### 4. All 8 plugin bundles loaded unconditionally at launch

**Impact: ~20–40 MB at launch**
**File:** `Core/Plugins/PluginManager.swift` lines 44–63, 111

`loadAllPlugins()` calls `bundle.load()` on every `.tableplugin` bundle at startup, linking in static libraries for all 8 database engines (libmariadb, libpq, libfreetds, libmongoc, hiredis, etc.) regardless of whether the user connects to that database type.

**Fix options:**
- [x] Lazy-load plugins: only call `bundle.load()` when a connection of that type is first established — **Done**: `discoverPlugins()` reads Info.plist at launch, `loadPendingPlugins()` defers `bundle.load()` until first driver request
- [x] Keep the plugin discovery (reading Info.plist) at launch but defer `bundle.load()` + principal class instantiation — **Done**: same as above

---

### 5. Undo stack stores full row copies

**Impact: Up to 100 × row-width per tab with unsaved changes**
**Files:**
- `Core/ChangeTracking/DataChangeUndoManager.swift` lines 14–19
- `Core/ChangeTracking/DataChangeModels.swift` lines 82–84

`UndoAction.rowDeletion(rowIndex:originalRow:)` stores a complete `[String?]` for every deleted row. The undo stack is capped at 100 entries, but batch deletions (`.batchRowDeletion(rows:)`) can store hundreds of full row copies in a single entry. On a table with 50 columns and large text values, this can consume tens of MB.

**Fix options:**
- [ ] Store only changed cells (column index + old value) instead of full rows for modifications
- [ ] For deletions, store row indices and reconstruct from `RowBuffer` on undo (if rows haven't been evicted)
- [ ] Reduce `maxUndoDepth` for batch operations or cap total undo memory

---

### 6. Duplicate schema/table list

**Impact: ~1–5 MB for large schemas (500+ tables)**
**Files:**
- `Models/Connection/ConnectionSession.swift` line 23 — `tables: [TableInfo]`
- `Core/Autocomplete/SQLSchemaProvider.swift` line 14 — `tables: [TableInfo]`

The table list is stored in both `ConnectionSession.tables` (used by sidebar) and `SQLSchemaProvider.tables` (used by autocomplete). These are independent copies of the same data.

**Fix options:**
- [ ] Make `SQLSchemaProvider` the single source of truth; have sidebar read from it
- [ ] Or store tables only in `ConnectionSession` and have `SQLSchemaProvider` reference it

---

### 7. `TabPendingChanges` duplicated during tab switch

**Impact: Proportional to unsaved edits, transient**
**Files:**
- `Models/Query/QueryTab.swift` line 338 — `pendingChanges: TabPendingChanges`
- `Core/ChangeTracking/DataChangeManager.swift` — live change state

On tab switch, `DataChangeManager.saveState()` copies all changes into `QueryTab.pendingChanges`. During the transition, both `DataChangeManager` and `TabPendingChanges` hold the same data. The old `DataChangeManager` state is cleared after, but there's a window of double memory.

**Fix options:**
- [ ] Use move semantics (`consuming` parameter) to transfer ownership instead of copying

---

### 8. `NSWindow.didUpdateNotification` observer with no window filter

**Impact: CPU overhead (not memory), scales with tab count**
**File:** `Views/Editor/SQLEditorCoordinator.swift` lines 273–283

Each `SQLEditorCoordinator` registers for `NSWindow.didUpdateNotification` with `object: nil`, meaning every editor instance's closure fires on every window update cycle across all windows. With N query tabs, N closures fire per update cycle.

**Fix options:**
- [x] Filter by `object: textView.window` after the editor's window is known — **Done**: notification handler early-returns when `notification.object` doesn't match the editor's own window
- [ ] Or use KVO on the specific window's `firstResponder` instead

---

### 9. `RowBuffer.sourceQuery` duplicates `QueryTab.query`

**Impact: Up to query size per tab (typically <500 KB)**
**Files:**
- `Models/Query/QueryTab.swift` line 258 — `RowBuffer.sourceQuery`
- `Views/Main/Extensions/MainContentCoordinator+TabSwitch.swift` line 127

Before eviction, `tab.query` is copied into `rowBuffer.sourceQuery` so the query can be re-executed on rehydration. Both `tab.query` and `rowBuffer.sourceQuery` then hold the same string.

**Fix options:**
- [x] Remove `sourceQuery` from `RowBuffer`; read from `tab.query` on rehydration instead — **Done**: removed `sourceQuery` property and its assignment in eviction

---

### 10. Per-window overhead from native tab architecture

**Impact: ~5–15 MB per window (coordinator + services + NSWindow object tree)**

Each macOS native tab creates a full `NSWindow` with its own:
- `MainContentCoordinator` (owns `QueryTabManager`, `DataChangeManager`, `FilterStateManager`, `ConnectionToolbarState`, `TabPersistenceCoordinator`, `RowOperationsManager`)
- `NSTableView` + `NSTableColumn[]` for the data grid
- `NSScrollView` with its clip view and scroller views
- SwiftUI hosting infrastructure

This is inherent to the native-tab architecture and not easily reducible without moving to in-process tabs.

**Fix options:**
- [ ] Consider lightweight in-process tab bar (shared NSWindow) for table tabs — major architectural change
- [ ] Or accept this as the cost of native tabs and focus on reducing per-tab data overhead (items 2, 3, 5 above)

---

## Quick Wins (low effort, high impact)

| # | Fix | Expected Savings | Effort | Status |
|---|-----|-------------------|--------|--------|
| 3 | Cross-window eviction + clear `InMemoryRowProvider` on evict | Reclaim ~90 MB per evicted tab | Medium | **Done** |
| 2 | `InMemoryRowProvider` references `RowBuffer` instead of copying | -3–10 MB per tab | Medium | **Done** |
| 9 | Remove `RowBuffer.sourceQuery`, use `tab.query` | -0–500 KB per tab | Low | **Done** |
| 4 | Lazy plugin loading | -20–30 MB at launch | Low-Medium | **Done** |
| 1 | Eliminate dedicated ping driver + lazy metadata driver | -60–100 MB per connection | Medium | **Done** |

---

## Measurement Plan

To validate fixes, use Xcode Instruments with the **Allocations** and **Leaks** templates:

1. Launch app → record baseline
2. Connect to MySQL → record delta
3. Open table tab → record delta
4. Open 2 more table tabs → record per-tab delta
5. Close middle tab → verify memory is reclaimed
6. Switch tabs → verify eviction triggers

Track `VM Regions` and `All Heap Allocations` grouped by category. Filter by `TablePro` to exclude system framework overhead.

Use `vmmap --summary <pid>` for a quick per-region breakdown from Terminal.
