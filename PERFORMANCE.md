# TablePro Performance Audit

Audit date: 2026-02-22 | Total issues: 45 | Fixed: 0 | Deferred: 0

## Status Legend

- OPEN — Not yet addressed
- FIXED — Merged to main
- DEFERRED — Too invasive; requires manual refactoring

---

## 1. Memory / RAM (15 issues)

| ID    | Issue                                                                           | Severity | Status | Commit |
| ----- | ------------------------------------------------------------------------------- | -------- | ------ | ------ |
| MEM-1 | `QueryTab` is a struct — every mutation CoW-copies entire result set            | Critical | OPEN   | —      |
| MEM-2 | `duplicateTab()` deep-copies all result rows into new tab                       | High     | OPEN   | —      |
| MEM-3 | Sort cache duplicates entire result set per sorted tab                          | High     | OPEN   | —      |
| MEM-4 | XLSX export accumulates all rows of all tables in memory                        | High     | OPEN   | —      |
| MEM-5 | `mysql_store_result` + redundant String copy doubles peak RAM                   | High     | OPEN   | —      |
| MEM-6 | Redundant deep copy in `executeQueryInternal` (triple-copy pipeline)            | Medium   | OPEN   | —      |
| MEM-7 | `InMemoryRowProvider.rowCache` duplicates data without eviction                 | Medium   | OPEN   | —      |
| MEM-8 | `DatabaseRowProvider` cache has no size limit or LRU eviction                   | Medium   | OPEN   | —      |
| MEM-9 | `SQLSchemaProvider` holds strong ref to `DatabaseDriver` (stale after disconnect) | Medium | OPEN   | —      |
| MEM-10 | Undo/redo stacks grow unbounded with `originalRow` copies                      | Medium   | OPEN   | —      |
| MEM-11 | `TabPendingChanges` duplicates change state on every tab switch (CoW amplifier) | Medium  | OPEN   | —      |
| MEM-12 | `currentQueryTask` captures coordinator strongly — delays dealloc              | Medium   | OPEN   | —      |
| MEM-13 | `ConnectionSession` tables/tabs arrays persist when connection is idle          | Low      | OPEN   | —      |
| MEM-14 | `AIChatViewModel` messages accumulate without limit                             | Low      | OPEN   | —      |
| MEM-15 | `XLSXWriter` sharedStrings table grows unbounded for large exports             | Low      | OPEN   | —      |

## 2. CPU / Main Thread (14 issues)

| ID    | Issue                                                                           | Severity | Status | Commit |
| ----- | ------------------------------------------------------------------------------- | -------- | ------ | ------ |
| CPU-1 | Redundant `unicodeScalars.map { Character($0) }` on every cell (MariaDB)       | Critical | OPEN   | —      |
| CPU-2 | Redundant `unicodeScalars.map { Character($0) }` on every cell (PostgreSQL)    | Critical | OPEN   | —      |
| CPU-3 | `SQLFormatterService` compiles 100+ regex patterns per format call              | High     | OPEN   | —      |
| CPU-4 | Synchronous Keychain I/O on `@MainActor` during connection setup               | High     | OPEN   | —      |
| CPU-5 | `uppercaseKeywords` builds 200+ branch alternation regex every format call      | High     | OPEN   | —      |
| CPU-6 | `stripLimitOffset` regex compiled on every call (MySQL/PostgreSQL/SQLite)       | Medium   | OPEN   | —      |
| CPU-7 | CSV export inline regex per row for decimal format detection                    | Medium   | OPEN   | —      |
| CPU-8 | `String.count` used on large strings in SQLFormatterService (O(n))             | Medium   | OPEN   | —      |
| CPU-9 | `addLineBreaks` compiles 16 regex patterns per format call                     | Medium   | OPEN   | —      |
| CPU-10 | `addIndentation` compiles regex per line for subquery/word boundary            | Medium   | OPEN   | —      |
| CPU-11 | `DataChangeManager.recordCellChange` linear search on changes array            | Medium   | OPEN   | —      |
| CPU-12 | Unused `loadPassword()` called for every connection at startup                 | Medium   | OPEN   | —      |
| CPU-13 | `extractTableName` regex compiled on every call                                | Low      | OPEN   | —      |
| CPU-14 | `isDangerousQuery` inline regex compiled per query execution                   | Low      | OPEN   | —      |

## 3. Large Data Handling (8 issues)

| ID     | Issue                                                                          | Severity | Status | Commit |
| ------ | ------------------------------------------------------------------------------ | -------- | ------ | ------ |
| DAT-1  | Query tabs have no LIMIT protection — unbounded SELECT can OOM                 | High     | OPEN   | —      |
| DAT-2  | `mysql_store_result` / `PQexec` load entire result set into client memory      | High     | OPEN   | —      |
| DAT-3  | SQLite driver fetches all rows into array without limit                        | Medium   | OPEN   | —      |
| DAT-4  | `SQLSchemaProvider` eagerly loads columns for ALL tables (N+1 queries)         | Medium   | OPEN   | —      |
| DAT-5  | Client-side sorting creates full memory copy for query tabs                    | Medium   | OPEN   | —      |
| DAT-6  | `InMemoryRowProvider` recreated on every SwiftUI render                        | Medium   | OPEN   | —      |
| DAT-7  | Clipboard copy builds unbounded string for large selections                    | Low      | OPEN   | —      |
| DAT-8  | `QueryResult.toQueryResultRows()` deep copy with UUID allocation per row       | Low      | OPEN   | —      |

## 4. Network / Database I/O (5 issues)

| ID     | Issue                                                                          | Severity | Status | Commit |
| ------ | ------------------------------------------------------------------------------ | -------- | ------ | ------ |
| NET-1  | Phase 2 metadata re-fetch on every query (columns, FKs, COUNT — 3 extra RTTs) | High     | OPEN   | —      |
| NET-2  | Missing `connect_timeout` in LibPQ connection string                           | High     | OPEN   | —      |
| NET-3  | No driver-level `cancelQuery()` — in-flight SQL continues after Task cancel    | Medium   | OPEN   | —      |
| NET-4  | `SidebarView.loadTables()` triggered by 3 notifications without deduplication  | Medium   | OPEN   | —      |
| NET-5  | `AIChatPanelView.fetchSchemaContext()` N+1 queries per table                   | Medium   | OPEN   | —      |

## 5. Disk I/O / UI Responsiveness (3 issues)

| ID     | Issue                                                                          | Severity | Status | Commit |
| ------ | ------------------------------------------------------------------------------ | -------- | ------ | ------ |
| IO-1   | `QueryHistoryStorage.performCleanup()` runs 3 SQLite ops on every INSERT      | High     | OPEN   | —      |
| IO-2   | `QueryHistoryStorage` uses blocking `queue.sync` for read operations           | High     | OPEN   | —      |
| IO-3   | `MainContentView` has 15+ onChange handlers creating cascading update chains   | Medium   | OPEN   | —      |

---

## Issue Details

### MEM-1: QueryTab struct CoW-copies entire result set on mutation

**File:** `Models/QueryTab.swift` (~220-316)

`QueryTab` is a `struct` holding `resultRows: [QueryResultRow]`. Every property mutation (e.g., `tabs[i].isExecuting = true`) triggers copy-on-write of the entire result array when the buffer is shared. `executeQueryInternal` does `var tab = tabs[i]` → mutate → `tabs[i] = tab`, creating temporary copies.

**Impact:** 10K rows × 20 columns = ~200K elements copied per tab mutation. RAM spikes 2-3× actual data size.

**Fix:** Convert `QueryTab` to a `class`, or extract `resultRows` into a `final class RowBuffer` reference wrapper.

---

### MEM-2: duplicateTab() deep-copies all result rows

**File:** `Models/QueryTab.swift` (~601-619)

Copies `resultRows`, `columnTypes`, `columnForeignKeys`, etc. from source to new tab.

**Impact:** Duplicating a tab with 50K rows doubles memory for that data.

**Fix:** Duplicate metadata only; re-execute query for the new tab on demand.

---

### MEM-3: Sort cache duplicates entire result set

**File:** `Views/Main/MainContentCoordinator.swift` (~795-831)

`querySortCache[tabId]` stores a complete `[QueryResultRow]` copy. Original unsorted rows remain in `resultRows`. Each sorted tab holds 2× its data.

**Fix:** Use an index permutation array `[Int]` instead of duplicating all rows.

---

### MEM-4: XLSX export accumulates all rows in memory

**File:** `Core/Services/ExportService.swift` (~304-358) + `Core/Services/XLSXWriter.swift`

Fetches all rows into `allRows: [[String?]]`, then `XLSXWriter` converts to `[[CellValue]]` + sharedStrings. Data exists 3× in memory.

**Fix:** Stream XLSX writing per-sheet in batches. Use inline strings to avoid shared string table.

---

### MEM-5: mysql_store_result + redundant String copy

**File:** `Core/Database/MariaDBConnection.swift` (~480-590)

`mysql_store_result()` buffers entire result in C memory. Then each string is copied via `String(str.unicodeScalars.map { Character($0) })`, creating intermediate `[Character]` array.

**Fix:** Use `mysql_use_result()` for large results (streaming). Remove `unicodeScalars.map` wrapper (see CPU-1).

---

### MEM-6: Triple-copy in executeQueryInternal

**File:** `Views/Main/MainContentCoordinator.swift` (~362-370)

After driver returns Swift-owned strings, code does `String($0)` deep copy on every value. Combined with C-level buffering (MEM-5), each string exists in up to 4 copies during transition.

**Fix:** Remove redundant `String($0)` wrapping. Driver strings are already Swift-owned.

---

### MEM-7: InMemoryRowProvider.rowCache duplicates data

**File:** `Models/RowProvider.swift` (~63-174)

`rowCache: [Int: TableRowData]` copies values from `sourceRows`. Scrolling through all rows duplicates the entire dataset. No eviction.

**Fix:** Have `TableRowData` reference source row directly, or eliminate cache.

---

### MEM-8: DatabaseRowProvider cache unbounded

**File:** `Models/RowProvider.swift` (~179-270)

`cache: [Int: TableRowData]` grows without limit during virtualized scrolling.

**Fix:** LRU eviction with configurable max (e.g., 10K rows).

---

### MEM-9: SQLSchemaProvider holds strong DatabaseDriver ref

**File:** `Core/Autocomplete/SQLSchemaProvider.swift` (~20, 32, 74)

`cachedDriver: DatabaseDriver?` keeps driver alive after disconnect if `invalidateCache()` not called.

**Fix:** Observe disconnect notification and clear cached driver.

---

### MEM-10: Undo/redo stacks unbounded

**File:** `Core/ChangeTracking/DataChangeUndoManager.swift` (~12-83)

`undoStack`/`redoStack` grow without limit. `UndoAction.rowDeletion` stores full row copy.

**Fix:** Cap stacks at configurable max depth (e.g., 100 actions).

---

### MEM-11: TabPendingChanges duplicated on tab switch

**File:** `Views/Main/MainContentCoordinator.swift` (~1399-1406)

`changeManager.saveState()` creates `TabPendingChanges` struct stored inside `QueryTab` (struct), amplifying CoW from MEM-1.

**Fix:** Store as reference type or in separate dictionary keyed by tab ID.

---

### MEM-12: currentQueryTask captures coordinator strongly

**File:** `Views/Main/MainContentCoordinator.swift` (~360)

`currentQueryTask = Task { ... }` captures `self` strongly. If window closes during long query, coordinator stays alive.

**Fix:** Use `[weak self]` capture in Task closure.

---

### CPU-1: Redundant unicodeScalars.map on every cell (MariaDB)

**File:** `Core/Database/MariaDBConnection.swift` (~519, 565, 569, 706, 804, 879, 1024, 1027)

`String(str.unicodeScalars.map { Character($0) })` iterates every scalar, creates `[Character]`, then new String. O(n) per cell.

**Impact:** 10K rows × 20 cols = 200K unnecessary O(n) copies.

**Fix:** Remove wrapper entirely — `String(bytes:encoding:)` already produces independent String.

---

### CPU-2: Redundant unicodeScalars.map on every cell (PostgreSQL)

**File:** `Core/Database/LibPQConnection.swift` (~493, 526, 537)

Same pattern as CPU-1 for PostgreSQL driver.

**Fix:** Same — remove `unicodeScalars.map` wrapper.

---

### CPU-3: SQLFormatterService compiles 100+ regex per format call

**File:** `Core/Services/SQLFormatterService.swift` (~155-408)

`createRegex()` compiles new `NSRegularExpression` every call. Single format: ~40+ compilations across `extractStringLiterals`, `extractComments`, `uppercaseKeywords`, `addLineBreaks`, `addIndentation`.

**Fix:** Cache all patterns as `static let` properties.

---

### CPU-4: Synchronous Keychain I/O on @MainActor

**File:** `Core/Database/DatabaseManager.swift` (~85-86, 270-271)

`connectToSession()` is `@MainActor` and calls `loadSSHPassword`/`loadKeyPassphrase` synchronously. `SecItemCopyMatching` blocks 10-50ms.

**Fix:** Move Keychain reads to `Task.detached`.

---

### CPU-5: uppercaseKeywords builds 200+ alternation regex every call

**File:** `Core/Services/SQLFormatterService.swift` (~233-256)

Unions all keywords + functions + types, builds `\b(SELECT|FROM|...)\b` with 200+ branches, compiles from scratch.

**Fix:** Cache compiled regex per `DatabaseType`.

---

### CPU-6: stripLimitOffset regex compiled on every call (3 drivers)

**Files:** `MySQLDriver.swift` (~503-521), `PostgreSQLDriver.swift` (~531-547), `SQLiteDriver.swift` (~672-688)

Two `NSRegularExpression` compiled per call. Called on every paginated query.

**Fix:** Move to `private static let`.

---

### CPU-7: CSV export inline regex per row

**File:** `Core/Services/ExportService.swift` (~471)

`range(of:options:.regularExpression)` compiles regex internally per cell for decimal detection. 100K rows × 20 cols = 2M compilations.

**Fix:** Pre-compile as `static let`.

---

### CPU-8: String.count on large strings (O(n))

**File:** `Core/Services/SQLFormatterService.swift` (~52-53, 435-438)

`sql.count` traverses entire string (counts grapheme clusters). On 10MB SQL file, two O(n) passes.

**Fix:** Use `(sql as NSString).length` (O(1)).

---

### CPU-9: addLineBreaks compiles 16 regex patterns per format

**File:** `Core/Services/SQLFormatterService.swift` (~260-285)

Iterates 16 SQL keywords, compiling fresh regex for each.

**Fix:** Pre-compile as static array.

---

### CPU-10: addIndentation compiles regex per line

**File:** `Core/Services/SQLFormatterService.swift` (~289-334)

`hasWordBoundary` + subquery regex compiled per line. 50-line SQL = 150 compilations.

**Fix:** Pre-compile fixed patterns as `static let`.

---

### CPU-11: recordCellChange linear search

**File:** `Core/ChangeTracking/DataChangeManager.swift` (~136, 181)

`changes.firstIndex(where:)` is O(n) on every cell edit.

**Fix:** Add `changeIndexByRow: [Int: Int]` dictionary for O(1) lookup.

---

### CPU-12: Unused loadPassword() called at startup

**File:** `Core/Storage/ConnectionStorage.swift` (~42)

`loadConnections()` calls `_ = loadPassword(for:)` per connection. Result discarded. 20 connections = 20 Keychain IPCs.

**Fix:** Remove the unused call entirely.

---

### DAT-1: Query tabs have no LIMIT protection

**File:** `Views/Main/MainContentCoordinator.swift` (~335-578)

Table tabs use pagination (LIMIT/OFFSET). Query tabs execute raw SQL with no protection. `SELECT * FROM million_row_table` loads everything.

**Fix:** Auto-detect no-LIMIT queries and warn or auto-append configurable LIMIT.

---

### DAT-2: Drivers load entire result set into client memory

**Files:** `MariaDBConnection.swift` (~480), `LibPQConnection.swift` (~337-383)

`mysql_store_result()` and `PQexec()` buffer complete result in client memory before row iteration.

**Fix:** Streaming modes: `mysql_use_result()`, `PQsendQuery()` + `PQsetSingleRowMode()`, or cursors.

---

### DAT-3: SQLite fetches all rows without limit

**File:** `Core/Database/SQLiteDriver.swift` (~88-105)

`while sqlite3_step == SQLITE_ROW` loop appends without bound.

**Fix:** Add configurable row limit parameter.

---

### DAT-4: SQLSchemaProvider N+1 queries

**File:** `Core/Autocomplete/SQLSchemaProvider.swift` (~41-52)

1 query for tables + N queries for columns. 500 tables = 501 queries.

**Fix:** Single `INFORMATION_SCHEMA.COLUMNS` query partitioned by table name.

---

### DAT-5: Client-side sorting copies full result for query tabs

**File:** `Views/Main/MainContentCoordinator.swift` (~753-867)

Query tab sort creates full sorted copy + sort cache (MEM-3).

**Fix:** Wrap query as subquery with server-side `ORDER BY`.

---

### DAT-6: InMemoryRowProvider recreated every SwiftUI render

**File:** `Views/Main/Child/TableTabContentView.swift` (~71-78)

`InMemoryRowProvider(rows: sortedRows, ...)` created in `body`, resetting cache each time.

**Fix:** Cache provider in `@State` or coordinator; recreate only when data changes.

---

### DAT-7: Clipboard copy builds unbounded string

**File:** `Core/Services/RowOperationsManager.swift` (~298)

All selected rows → single tab-separated string. 100K rows = hundreds of MB string.

**Fix:** Warn above threshold (e.g., 10K rows) or use file promise.

---

### DAT-8: toQueryResultRows() deep copy + UUID per row

**File:** `Models/QueryResult.swift`

Creates `[QueryResultRow]` from `[[String?]]` with UUID per row, doubling memory temporarily.

**Fix:** Use integer indices instead of UUIDs. Avoid keeping both representations.

---

### NET-1: Phase 2 metadata re-fetch on every query

**File:** `Views/Main/MainContentCoordinator.swift` (~429-514)

`fetchColumns`, `fetchForeignKeys`, `SELECT COUNT(*)` re-run on every query even for same table.

**Fix:** Cache per table name on tab. Skip Phase 2 when already populated.

---

### NET-2: Missing connect_timeout in LibPQ

**File:** `Core/Database/LibPQConnection.swift` (~180-220)

`PQconnectdb()` blocks indefinitely if server unreachable. No timeout set.

**Fix:** Add `connect_timeout=10` to connection string.

---

### NET-3: No driver-level cancelQuery()

**Files:** `DatabaseDriver.swift` (protocol), all drivers

Swift Task cancellation doesn't cancel in-flight SQL. `PQexec`/`mysql_real_query` block until done.

**Fix:** Add `cancelQuery()` using `PQcancel()`, `mysql_kill()`, `sqlite3_interrupt()`.

---

### NET-4: SidebarView.loadTables() triple-triggered

**File:** `Views/Sidebar/SidebarView.swift` (~75-89)

`.databaseDidConnect`, `.refreshData`, `.refreshAll` all call `loadTables()`. Can fire together on connect.

**Fix:** Deduplicate with `isLoading` guard or consolidate notifications.

---

### NET-5: AI chat N+1 schema queries

**File:** `Views/AIChat/AIChatPanelView.swift` (~340-375)

Loops tables calling `fetchColumns()` + `fetchForeignKeys()` per table.

**Fix:** Reuse cached schema from `SQLSchemaProvider`.

---

### IO-1: performCleanup() runs on every history INSERT

**File:** `Core/Storage/QueryHistoryStorage.swift` (~184-185)

Every `addHistory()` runs 3 SQLite cleanup queries.

**Fix:** Throttle to every 100 inserts or once per app launch.

---

### IO-2: QueryHistoryStorage uses blocking queue.sync

**File:** `Core/Storage/QueryHistoryStorage.swift` (~234-409)

`fetchHistory()`, `deleteHistory()`, `getHistoryCount()` use `queue.sync`. Can block main thread.

**Fix:** Migrate callers to existing async wrappers.

---

### IO-3: 15+ onChange handlers in MainContentView

**File:** `Views/MainContentView.swift` (~141-211)

Multiple handlers fire when query completes, each triggering SwiftUI re-evaluation.

**Fix:** Batch related property updates. Consolidate handlers for related events.

---

## Priority Matrix

### Quick Wins (high impact, low effort)

| ID     | Issue                              | Effort   |
| ------ | ---------------------------------- | -------- |
| CPU-1  | Remove unicodeScalars.map (MySQL)  | 1-line   |
| CPU-2  | Remove unicodeScalars.map (PG)     | 1-line   |
| CPU-12 | Remove unused loadPassword() call  | 1-line   |
| NET-2  | Add connect_timeout to LibPQ       | 1-line   |
| IO-1   | Throttle history cleanup           | 5-line   |
| CPU-6  | Cache stripLimitOffset regex       | Static   |
| CPU-13 | Cache extractTableName regex       | Static   |
| CPU-14 | Cache isDangerousQuery regex       | Static   |
| CPU-7  | Cache CSV decimal regex            | Static   |

### Medium Effort (significant impact)

| ID     | Issue                              | Effort   |
| ------ | ---------------------------------- | -------- |
| CPU-3  | Cache SQLFormatter regex patterns  | Moderate |
| NET-1  | Cache Phase 2 metadata per table   | Moderate |
| MEM-3  | Index-based sort cache             | Moderate |
| MEM-6  | Remove redundant deep copy         | Moderate |
| DAT-1  | Query tab LIMIT protection         | Moderate |
| DAT-4  | Single schema query (not N+1)      | Moderate |
| IO-2   | Migrate to async history methods   | Moderate |

### Large Effort (architectural changes)

| ID     | Issue                              | Effort   |
| ------ | ---------------------------------- | -------- |
| MEM-1  | QueryTab struct → class            | Large    |
| MEM-4  | Streaming XLSX export              | Large    |
| DAT-2  | Streaming result set fetching      | Large    |
| NET-3  | Driver-level query cancellation    | Large    |
