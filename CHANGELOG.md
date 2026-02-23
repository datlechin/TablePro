# Changelog

All notable changes to TablePro will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.4] - 2026-02-23

### Fixed
- Fix PostgreSQL SQL export failing to fetch DDL for tables (passed quoted identifier instead of raw table name to catalog queries)

## [0.6.3] - 2026-02-23

### Changed
- Extract shared `performDirectTabSwitch` into `MainContentCoordinator` to eliminate duplicate tab-switch logic
- Welcome window now uses native macOS frosted glass translucency (NSVisualEffectView with behind-window blending)

### Fixed
- Auto-detect MySQL vs MariaDB server type from version string to use correct timeout variable (`max_execution_time` for MySQL, `max_statement_time` for MariaDB)
- Improved tab switching performance by caching row providers and change managers across SwiftUI render cycles
- Eliminated selection sync feedback loop causing redundant DataGridView updates during tab switch
- Enabled NSTableView row view recycling to reduce heap allocations during scrolling
- Reduced SwiftUI re-render cascades by batching @Published mutations during tab switch
- Improved DataGrid scrolling performance:
  - Row views now recycled via NSTableView's reuse pool instead of allocating new objects per scroll
  - Replaced O(n) String.count with O(1) NSString.length for large cell value truncation
  - Replaced expensive NSFontDescriptor.symbolicTraits checks with O(1) pointer equality on cached fonts
  - Added layerContentsRedrawPolicy and canDrawSubviewsIntoLayer to reduce compositing overhead
  - Cached NULL display string locally instead of per-cell singleton access
  - Cached AnyChangeManager to avoid per-render allocation with Combine subscriptions
  - Deferred accessibility label generation to when VoiceOver is active
  - Removed unnecessary async dispatch in focusedColumn, collapsed two reloadData calls into one

## [0.6.2] - 2026-02-23

## [0.6.1] - 2026-02-23

### Fixed
- Fixed all 45 performance issues identified in PERFORMANCE.md audit:
  - **Memory:** RowBuffer reference wrapper for QueryTab (MEM-1/2), index-based sort cache (MEM-3), streaming XLSX export with inline strings (MEM-4/15), driver-level row limits cap at 100K rows (MEM-5), removed redundant String deep copies (MEM-6), weak driver reference in SQLSchemaProvider (MEM-9), undo stack depth cap (MEM-10), dictionary-based tab pending changes (MEM-11), weak self in Task captures (MEM-12), clear cached data on disconnect (MEM-13), AI chat message cap (MEM-14)
  - **CPU:** Removed unicodeScalars.map in MariaDB/PostgreSQL drivers (CPU-1/2), cached 100+ regex patterns in SQLFormatterService (CPU-3/5/8/9/10), async Keychain reads (CPU-4), cached stripLimitOffset/extractTableName/isDangerousQuery regex (CPU-6/13/14), cached CSV decimal regex (CPU-7), O(1) change lookup index (CPU-11), removed unused loadPassword call (CPU-12)
  - **Data handling:** Auto-append LIMIT 10000 for unprotected queries (DAT-1), driver-level row limit cap for MySQL/PostgreSQL (DAT-2), SQLite row limit cap at 100K (DAT-3), batch fetchAllColumns via INFORMATION_SCHEMA (DAT-4), index permutation sort cache (DAT-5), cached InMemoryRowProvider in @State (DAT-6), clipboard 50K row cap (DAT-7), Int-based row IDs replacing UUID allocation (DAT-8)
  - **Network:** Phase 2 metadata cache check (NET-1), connect_timeout for LibPQ (NET-2), driver-level cancelQuery via mysql_kill/PQcancel/sqlite3_interrupt (NET-3), isLoading guard for sidebar (NET-4), reuse cached schema for AI chat (NET-5)
  - **I/O:** Throttled history cleanup (IO-1), async history storage migration (IO-2), consolidated onChange handlers (IO-3)

## [0.6.0] - 2026-02-22

### Added
- Inline AI suggestions (ghost text) in the SQL editor — auto-triggers on typing pause, Tab to accept, Escape to dismiss
- Schema-aware inline suggestions — AI now uses actual table/column names from the connected database (cached with 30s TTL, respects `includeSchema` and `maxSchemaTables` settings)
- AI feature highlight row on onboarding features page
- Added VoiceOver accessibility labels to custom controls: data grid (table view, column headers, cells), filter panel (logic toggle, presets, action buttons, filter row controls), toolbar buttons (connection switcher, database switcher, refresh, export, import, filter toggle, history toggle, inspector toggle), editor tab bar (tab items, close buttons, add tab button), and sidebar (table/view rows, search clear button)

### Changed
- Migrated notification observers in `MainContentCommandActions` from Combine publishers (`.publisher(for:).sink`) to async sequences (`for await` over `NotificationCenter.default.notifications(named:)`) — removes `AnyCancellable` storage in favor of `Task` handles with proper cancellation on deinit
- Migrated tab state persistence from UserDefaults to file-based storage in Application Support — prevents large JSON payloads from bloating the plist loaded at app launch, with automatic one-time migration of existing data
- Refactored menu and toolbar commands from NotificationCenter to `@FocusedObject` pattern — menu commands and toolbar buttons now call `MainContentCommandActions` methods directly instead of posting global notifications, with context-aware routing for structure view operations
- Redesigned connection form with tab-based layout (General / SSH Tunnel / SSL/TLS / Advanced), replacing the single-scroll layout
- Revamped connection form UI to use native macOS grouped form style (`Form`/`.formStyle(.grouped)`) with `LabeledContent` for automatic label-value alignment and `Section` headers — replacing the previous hand-rolled `VStack` layout with custom `FormField` component
- Removed unused `FormField` component and helper methods (`iconForType`, `colorForType`)
- SQLite connections now only show General and Advanced tabs (SSH/SSL hidden)
- Added async/await wrapper methods to `QueryHistoryStorage` — existing completion-handler API preserved for compatibility, new `async` overloads use `withCheckedContinuation` for modern Swift concurrency callers

### Fixed
- Fixed TOCTOU race condition in `SQLiteDriver` — replaced `nonisolated(unsafe)` + DispatchQueue pattern with a dedicated actor (`SQLiteConnectionActor`) that serializes all sqlite3 handle access, preventing concurrent task races on the connection state
- Consolidated multiple `.sheet(isPresented:)` modifiers in `MainContentView` into a single `.sheet(item:)` with an `ActiveSheet` enum — fixes SwiftUI anti-pattern where only the last `.sheet` modifier reliably activates
- Replaced blocking `Process.waitUntilExit()` calls in `SSHTunnelManager` with async `withCheckedContinuation`-based waiting, and replaced the fixed 1.5s sleep with active port probing — SSH tunnel setup no longer blocks the actor thread, keeping the UI responsive during connection
- Eliminated potential deadlocks in `MariaDBConnection` and `LibPQConnection` — replaced all `queue.sync` calls (in `disconnect`, `deinit`, `isConnected`, `serverVersion`) with lock-protected cached state and `queue.async` cleanup, preventing deadlocks when callbacks re-enter the connection queue
- SQL editor now respects the macOS accessibility text size preference (System Settings > Accessibility > Display > Text Size) — the user's chosen font size is scaled by the system's preferred text size factor, with live updates when the setting changes
- Fixed retain cycle in `UpdaterBridge` — `.assign(to:on:self)` retains self strongly; replaced with `.sink` using `[weak self]`
- Fixed leaked NotificationCenter observer in `SQLEditorCoordinator` — observer token is now stored and removed in `destroy()`
- Eliminated tab switching delay — replaced view teardown/recreation with `ZStack`+`ForEach` to keep NSViews alive, moved tab persistence I/O to background threads, skipped unnecessary change-tracking deep copies, and coalesced redundant inspector/sidebar updates during tab switch
- Reduced tab-switch CPU spikes from 40-60% to ~10-20% by eliminating redundant `reloadData()` calls: `configureForTable` no longer triggers a reload during tab switch (single controlled bump instead of 2-3), `onChange(of: resultColumns)` is suppressed while the switch is in progress, and `DataGridView.updateNSView` skips all heavy work when the data identity hasn't changed
- Table open now shows data instantly — split `executeQueryInternal` into two phases: rows display immediately after SELECT completes, metadata (columns, FKs, enums, row count) loads in the background without blocking the grid
- Eliminated 20-80ms overhead when clicking an already-open table in the sidebar — `openTableTab` short-circuits immediately, and `TableProTabSmart` no longer fires `@Published` when the selected tab hasn't changed
- Keychain `SecItemAdd` return values are now checked and logged — previously, failed writes (e.g. `errSecDuplicateItem`, `errSecInteractionNotAllowed`) were silently discarded, risking password loss
- Added `kSecAttrService` to all Keychain queries across `ConnectionStorage`, `LicenseStorage`, and `AIKeyStorage` — items now have a proper service identifier, preventing potential collisions with other apps
- Ensured proper cleanup for `@State` reference type tokens — tracked untracked `Task` instances in `ImportDialog` (file selection), `AIProviderEditorSheet` (model fetching, connection test), and added `onDisappear` cancellation to prevent leaked work after view dismissal
- Replaced `.onAppear` with `.task` for I/O operations in `ConnectionTagEditor` — uses SwiftUI-idiomatic lifecycle-tied loading instead of `onAppear` which can re-fire on navigation

## [0.5.0] - 2026-02-19

### Changed
- AI chat panel — native macOS inspector styling: removed iOS-style chat bubbles, flattened message layout with role headers and compact spacing, reduced heading sizes for narrow sidebar, inline typing indicator without pill background
- **AppKit → SwiftUI migration:** migrated 5 NSPopover controllers (Enum, Set, TypePicker, JSONEditor, ForeignKey) to SwiftUI content views with a shared `PopoverPresenter` utility — eliminates manual `NSEvent` monitors, `NSPopoverDelegate`, and singleton patterns
- **AppKit → SwiftUI migration:** replaced `KeyEventHandler` NSViewRepresentable with native `.onKeyPress()` modifiers (macOS 14+) in DatabaseSwitcherSheet and WelcomeWindowView
- **AppKit → SwiftUI migration:** replaced AppKit history panel (5 files: `HistoryPanelController`, `HistoryListViewController`, `QueryPreviewViewController`, `HistoryTableView`, `HistoryRowView`) with single pure SwiftUI `HistoryPanelView` using `HSplitView`, `List` with selection, context menus, and swipe-to-delete
- **AppKit → SwiftUI migration:** replaced `ExportTableOutlineView` (NSOutlineView, 757 lines across 2 files) with SwiftUI `ExportTableTreeView` using `List`, `DisclosureGroup`, and tristate checkboxes (~146 lines)
- **Design tokens:** replaced hardcoded `Color.secondary.opacity(0.6)` with system `Color(nsColor: .tertiaryLabelColor)` in `DesignConstants` and `ToolbarDesignTokens` for proper semantic color

### Added
- AI chat panel shows "Set Up AI Provider" empty state when no AI provider is configured, with a button to open Settings
- AI chat panel — right-side panel for AI-assisted SQL queries with multi-provider support (Claude, OpenAI, OpenRouter, Ollama, custom endpoints)
- AI provider settings — configure multiple AI providers in Settings > AI with API key management (Keychain), endpoint configuration, model selection, and connection testing
- AI feature routing — map AI features (Chat, Explain Query, Fix Error, Inline Suggestions) to specific providers and models
- AI schema context — automatically includes database schema, current query, and query results in AI conversations for context-aware assistance
- AI chat code blocks — SQL code blocks in AI responses include Copy and Insert to Editor buttons
- AI chat markdown rendering — replaced custom per-line AttributedString parsing with MarkdownUI library for full CommonMark + GitHub Flavored Markdown support (proper lists, tables, blockquotes, headers, strikethrough)
- Per-connection AI policy — control AI access per connection (Always Allow, Ask Each Time, Never) in the connection form
- Toggle AI Chat keyboard shortcut (`⌘⇧L`) and toolbar button
- Tab reuse setting — opt-in option in Settings > Tabs to reuse clean table tabs when clicking a new table in the sidebar (off by default)
- Structure view: full undo/redo support (⌘Z / ⇧⌘Z) for all column, index, and foreign key operations
- Structure view: database-specific type picker popover for the Type column — searchable, grouped by category (Numeric, String, Date & Time, Binary, Other), supports freeform input for parametric types like `VARCHAR(255)`
- Structure view: YES/NO dropdown menu for Nullable, Auto Inc, and Unique columns (replaces freeform text input)
- Structure view: "Don't show again" toggle in SQL preview sheet now correctly skips the review step on future saves
- SQL autocomplete: new clause types — RETURNING, UNION/INTERSECT/EXCEPT, OVER/PARTITION BY, USING, DROP/CREATE INDEX/VIEW
- SQL autocomplete: smart clause transition suggestions (e.g., WHERE after FROM, HAVING after GROUP BY, LIMIT after ORDER BY)
- SQL autocomplete: qualified column suggestions (`table.column`) in JOIN ON clauses and `table.*` in SELECT
- SQL autocomplete: compound keyword suggestions — `IS NULL`, `IS NOT NULL`, `NULLS FIRST`, `NULLS LAST`, `ON CONFLICT`, `ON DUPLICATE KEY UPDATE`
- SQL autocomplete: richer column metadata in suggestions (primary key, nullability, default value, comment)
- SQL autocomplete: keyword documentation in completion popover
- SQL autocomplete: expanded keyword and function coverage — window functions, PostgreSQL/MySQL-specific, transaction, DCL, aggregate, datetime, string, numeric, JSON
- SQL autocomplete: context-aware suggestions for ALTER TABLE, INSERT INTO, CREATE TABLE, and COUNT(*)
- SQL autocomplete: improved fuzzy match scoring — prefix and contains matches rank above fuzzy-only matches
- Keyboard shortcut customization in Settings > Keyboard — rebind any menu shortcut via press-to-record UI, with conflict detection and "Reset to Defaults" support
- Keyboard shortcut for Switch Connection (`⌘⌥C`) — quickly open the connection switcher popover from the menu or keyboard

### Changed

- **Layout architecture:** replaced `SplitViewMinWidthEnforcer` NSViewRepresentable hack with proper AppDelegate-based inspector split view configuration — eliminates KVO observation, 300ms sleep, and recursive view tree traversal
- **Inspector data flow:** replaced manual snapshot syncing (`syncRightPanelSnapshotData()` + 5 `onChange` handlers) with `InspectorContext` value type passed directly through the view hierarchy via `@Binding`
- **Right panel state:** `RightPanelState` no longer holds snapshot copies of coordinator data or a weak coordinator reference — it now only manages panel visibility, tab state, and owned objects
- **AI chat panel:** receives `currentQuery: String?` parameter instead of a `MainContentCoordinator` reference — better separation of concerns
- **Sidebar save:** replaced `.saveSidebarChanges` notification with direct closure (`RightPanelState.onSave`) set by the notification handler
- Structure tab grid columns now auto-size to fit content on data load
- Structure view column headers and status messages are now localized
- SQL autocomplete: 50ms debounce for completion triggers to reduce unnecessary work
- SQL autocomplete: fuzzy matching rewritten for O(1) character access performance

### Fixed

- **Structure view:** undo/redo (⌘Z / ⇧⌘Z) now works for all schema editing operations — previously non-functional
- **Structure view:** undo-delete no longer duplicates existing rows in the grid
- **Structure view:** deleting a new (unsaved) item then undoing correctly re-adds it
- **Structure view:** save button now disabled when validation errors exist (empty column names/types)
- **Structure view:** validation now rejects indexes and foreign keys referencing columns pending deletion
- **Structure view:** multi-column foreign keys are correctly preserved instead of being truncated to single-column
- **Structure view:** renaming a MySQL/MariaDB column now uses `CHANGE COLUMN` instead of `MODIFY COLUMN` (which cannot rename)
- **Structure view:** eliminated redundant `discardChanges()` and `loadSchemaForEditing()` calls on save and initial load
- **PostgreSQL:** DDL tab now includes PRIMARY KEY, UNIQUE, CHECK, and FOREIGN KEY constraints plus standalone indexes
- **PostgreSQL:** primary key columns are now correctly detected and displayed in the structure grid
- **Security:** escape table and database names in all driver schema queries to prevent SQL injection from names containing special characters
- **SQL editor:** undo/redo (⌘Z / ⇧⌘Z) now works correctly (was blocked by responder chain selector mismatch)
- **SQL autocomplete:** clause detection now works correctly inside subqueries
- **SQL autocomplete:** block comment detection no longer treats `--` inside `/* */` as a line comment
- **SQL autocomplete:** database-specific type keywords (e.g., PostgreSQL `JSONB`, MySQL `ENUM`) now appear in suggestions
- **SQL autocomplete:** schema suggestions no longer disappear after CREATE TABLE
- **SQL autocomplete:** function completion now inserts `COUNT()` with cursor between parentheses instead of `COUNT(`
- **SQL autocomplete:** RETURNING suggestions now work after INSERT INTO and after closed `VALUES (...)` parentheses
- **SQL autocomplete:** CREATE INDEX ON suggests columns from the referenced table instead of table names
- **SQL autocomplete:** transition keywords (WHERE, JOIN, ORDER BY) no longer buried under columns at clause boundaries
- **SQL autocomplete:** schema-qualified names (e.g., `schema.table.column`) handled correctly
- **Data grid:** column order no longer flashes/swaps when sorting (stable identifiers for layout persistence)
- **Data grid:** "Copy Column Name" and "Filter with column" context menu actions no longer copy sort indicators (e.g., "name 1▲")
- **SQL generation:** ALTER TABLE, DDL, and SQL Preview statements now consistently end with a semicolon
- **AI chat:** "Ask Each Time" connection policy now shows a confirmation dialog before sending data to AI — previously silently fell through to "Always Allow"

### Removed

- Deleted unused `StructureTableCoordinator.swift` (~275 lines of dead code)
- Deleted 5 dead NSToolbar files (`ToolbarController`, `ToolbarWindowConfigurator`, `ToolbarItemFactory`, `ToolbarItemIdentifier`, `ToolbarHostingViews`) — never referenced by active code
- Removed `SplitViewMinWidthEnforcer` struct from `ContentView.swift`
- Removed `.saveSidebarChanges` notification definition and subscription

## [0.4.0] - 2026-02-16

### Added

- SQL Preview button (eye icon) in toolbar to review all pending SQL statements before committing changes (⌘⇧P)
- Multi-column sorting: Shift+click column headers to add columns to the sort list; regular click replaces with single sort. Sort priority indicators (1▲, 2▼) are shown in column headers when multiple columns are sorted
- "Copy with Headers" feature (Shift+Cmd+C) to copy selected rows with column headers as the first TSV line, also available via context menu in the data grid
- Column width persistence within tab session: resized columns retain their width across pagination, sorting, and filtering reloads
- Dangerous query confirmation dialog for `DELETE`/`UPDATE` statements without a `WHERE` clause — summarizes affected queries before execution
- SQL editor horizontal scrolling for long lines without word wrapping
- Scroll-to-match navigation in SQL editor find panel
- GitHub Sponsors funding configuration

### Changed

- Raise minimum macOS version from 13.5 (Ventura) to 14.0 (Sonoma)
- Change Export/Import keyboard shortcuts from ⌘E/⌘I to ⇧⌘E/⇧⌘I to avoid conflicts with standard text editing shortcuts
- Configure URLSession to wait for network connectivity in analytics and license services
- Improve SQL statement parser to handle backslash escapes within string literals, preventing false positives in dangerous query detection

### Fixed

- Fix SQL editor not updating colors when switching between light and dark mode
- Fix sidebar retaining stale table selections and pending operations for tables that no longer exist after a database refresh

## [0.3.2] - 2026-02-14

### Fixed

- Fix launch crash on macOS 13 (Ventura) x86_64 caused by accessing `NSApp.appearance` before `NSApplication` is initialized during settings singleton setup

## [0.3.1] - 2026-02-14

### Fixed

- Fix syntax highlighting not applying after paste in SQL editor — defer frame-change notification so the visible range recalculates after layout processes the new text
- Fix data grid not refreshing after inserting a new row by incrementing `reloadVersion` on row insertion

## [0.3.0] - 2026-02-13

### Added
- AI chat panel — right-side panel for AI-assisted SQL queries with multi-provider support (Claude, OpenAI, OpenRouter, Ollama, custom endpoints)
- AI provider settings — configure multiple AI providers in Settings > AI with API key management (Keychain), endpoint configuration, model selection, and connection testing
- AI feature routing — map AI features (Chat, Explain Query, Fix Error, Inline Suggestions) to specific providers and models
- AI schema context — automatically includes database schema, current query, and query results in AI conversations for context-aware assistance
- AI chat code blocks — SQL code blocks in AI responses include Copy and Insert to Editor buttons
- Per-connection AI policy — control AI access per connection (Always Allow, Ask Each Time, Never) in the connection form
- Toggle AI Chat keyboard shortcut (`⌘⇧L`) and toolbar button


- Anonymous usage analytics with opt-out toggle in Settings > General > Privacy — sends lightweight heartbeat (OS version, architecture, locale, database types) every 24 hours to help improve TablePro; no personal data or queries are collected
- ENUM/SET column editor: double-click ENUM columns to select from a searchable dropdown popover, SET columns show a multi-select checkbox popover with OK/Cancel buttons
- PostgreSQL user-defined enum type support via `pg_enum` catalog lookup
- SQLite CHECK constraint pseudo-enum detection (e.g., `CHECK(col IN ('a','b','c'))`)
- Language setting in General preferences (System, English, Vietnamese) with full Vietnamese localization (637 strings)
- Connection health monitoring with automatic reconnection for MySQL/MariaDB and PostgreSQL — pings every 30 seconds, retries 3 times with exponential backoff (2s/4s/8s) on failure
- Manual "Reconnect" toolbar button appears when connection is lost or in error state

### Changed

- Migrate `Libs/*.a` static libraries to Git LFS tracking to reduce repository clone size
- Remove stale `.gitignore` entries for architecture-specific MariaDB libraries
- Replace `filter { }.count` with `count(where:)` across 7 files for more efficient collection counting
- Replace `print()` with `Logger` in documentation examples and remove from `#Preview` blocks
- Replace `.count > 0` with `!.isEmpty` in documentation example

### Fixed

- Fix launch crash on macOS 13 caused by missing `asyncAndWait` symbol in CodeEditSourceEditor 0.15.2 (API requires macOS 14+); updated dependency to track `main` branch which uses `sync` instead
- Escape single quotes in PostgreSQL `pg_enum` lookup and SQLite `sqlite_master` queries to prevent SQL injection
- ENUM column nullable detection now uses actual schema metadata instead of heuristic rawType check
- PostgreSQL primary key modification now queries the actual constraint name from `pg_constraint` instead of assuming the `{table}_pkey` naming convention, supporting tables with custom constraint names
- Align Xcode `SWIFT_VERSION` build setting from 5.0 to 5.9 to match `.swiftformat` target version

## [0.2.0] - 2026-02-11

### Added
- AI chat panel — right-side panel for AI-assisted SQL queries with multi-provider support (Claude, OpenAI, OpenRouter, Ollama, custom endpoints)
- AI provider settings — configure multiple AI providers in Settings > AI with API key management (Keychain), endpoint configuration, model selection, and connection testing
- AI feature routing — map AI features (Chat, Explain Query, Fix Error, Inline Suggestions) to specific providers and models
- AI schema context — automatically includes database schema, current query, and query results in AI conversations for context-aware assistance
- AI chat code blocks — SQL code blocks in AI responses include Copy and Insert to Editor buttons
- Per-connection AI policy — control AI access per connection (Always Allow, Ask Each Time, Never) in the connection form
- Toggle AI Chat keyboard shortcut (`⌘⇧L`) and toolbar button


- SSL/TLS connection support for MySQL/MariaDB and PostgreSQL with configurable modes (Disabled, Preferred, Required, Verify CA, Verify Identity) and certificate file paths
- RFC 4180-compliant CSV parser for clipboard paste with auto-detection of CSV vs TSV format
- Explain Query button in SQL editor toolbar and menu item (⌥⌘E) for viewing execution plans
- Connection switcher popover for quick switching between active/saved connections from the toolbar
- Date/time picker popover for editing date, datetime, timestamp, and time columns in the data grid
- Read-only connection mode with toggle in connection form, toolbar badge, and UI-level enforcement (disables editing, row operations, and save changes)
- Configurable query execution timeout in Settings > General (default 60s, 0 = no limit) with per-driver enforcement via `statement_timeout` (PostgreSQL), `max_execution_time` (MySQL), `max_statement_time` (MariaDB), and `sqlite3_busy_timeout` (SQLite)
- Foreign key lookup dropdown for FK columns in the data grid — shows a searchable popover with values from the referenced table, displaying both the ID and a descriptive display column
- JSON column editor popover for JSON/JSONB columns with pretty-print formatting, compact mode, real-time validation, and explicit save/cancel buttons
- Excel (.xlsx) export format with lightweight pure-Swift OOXML writer — supports shared strings deduplication, bold header rows, numeric type detection, sheet name sanitization, and multi-table export to separate worksheets
- View management: Create View (opens SQL editor with template), Edit View Definition (fetches and opens existing definition), and Drop View from sidebar context menu. Adds `fetchViewDefinition()` to all database drivers (MySQL, PostgreSQL, SQLite)

### Fixed

- Fixed crash on launch on macOS 13 (Ventura) caused by missing Swift runtime symbol
- Fix redo functionality in data grid (Cmd+Shift+Z now works correctly)
- Fix redo stack not being cleared when new changes are made (standard undo/redo behavior)
- Fix `canRedo()` always returning false in data grid coordinator
- Wire undo/redo callbacks directly to data grid for proper responder chain validation
- Fix MariaDB connection error 1193 "Unknown system variable 'max_execution_time'" by using the correct `max_statement_time` variable for MariaDB
- Query timeout errors no longer prevent database connections from being established

### Changed

- Replace all `print()` statements with structured OSLog `Logger` across 25 files for better debugging via Console.app

## [0.1.1] - 2026-02-09

### Added
- AI chat panel — right-side panel for AI-assisted SQL queries with multi-provider support (Claude, OpenAI, OpenRouter, Ollama, custom endpoints)
- AI provider settings — configure multiple AI providers in Settings > AI with API key management (Keychain), endpoint configuration, model selection, and connection testing
- AI feature routing — map AI features (Chat, Explain Query, Fix Error, Inline Suggestions) to specific providers and models
- AI schema context — automatically includes database schema, current query, and query results in AI conversations for context-aware assistance
- AI chat code blocks — SQL code blocks in AI responses include Copy and Insert to Editor buttons
- Per-connection AI policy — control AI access per connection (Always Allow, Ask Each Time, Never) in the connection form
- Toggle AI Chat keyboard shortcut (`⌘⇧L`) and toolbar button


- Auto-update support via Sparkle 2 framework (EdDSA signed)
- "Check for Updates..." menu item in TablePro menu
- Software Update section in Settings > General with auto-check toggle
- CI appcast generation and auto-deploy on tagged releases

- Migrate SQL editor to CodeEditSourceEditor (tree-sitter powered)
- Multi-statement SQL execution support
- "Show Structure" context menu for sidebar tables
- Improved filter panel UI/UX
- SwiftUI EditorTabBar (replacing AppKit NativeTabBarView)
- GPL v3 license

### Fixed

- Fix MySQL 8+ connections failing with `caching_sha2_password` plugin error by rebuilding libmariadb.a with the auth plugin compiled statically
- Fix Delete key on data grid row from marking table as deleted
- Downgrade all APIs to support macOS 13.5 (Ventura)
- Code review fixes for multi-statement execution

### Changed

- CI release notes now read from CHANGELOG.md instead of auto-generating from commits
- Removed `prepare-libs` CI job to speed up build pipeline (~5 min savings)
- Add SPM Package.resolved for CodeEditSourceEditor dependencies
- Add Claude Code project settings
- Update build/test commands with `-skipPackagePluginValidation`

## [0.1.0] - 2026-02-05

### Initial Public Release

TablePro is a native macOS database client built with SwiftUI and AppKit, designed as a fast, lightweight alternative to TablePlus.

### Features

- **Database Support**
  - MySQL/MariaDB connections
  - PostgreSQL support
  - SQLite database files
  - SSH tunneling for secure remote connections

- **SQL Editor**
  - Syntax highlighting with TreeSitter
  - Intelligent autocomplete for tables, columns, and SQL keywords
  - Multi-tab editing support
  - Query execution with result grid

- **Data Management**
  - Interactive data grid with sorting and filtering
  - Inline editing capabilities
  - Add, edit, and delete rows
  - Pagination for large result sets
  - Export data (CSV, JSON, SQL)

- **Database Explorer**
  - Browse tables, views, and schema
  - View table structure and indexes
  - Quick table information and statistics
  - Search across database objects

- **User Experience**
  - Native macOS design with SwiftUI
  - Dark mode support
  - Customizable keyboard shortcuts
  - Query history tracking
  - Multiple database connections

- **Developer Features**
  - Import/export connection configurations
  - Custom SQL query templates
  - Performance optimized for large datasets

[Unreleased]: https://github.com/datlechin/tablepro/compare/v0.6.4...HEAD
[0.6.4]: https://github.com/datlechin/tablepro/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/datlechin/tablepro/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/datlechin/tablepro/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/datlechin/tablepro/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/datlechin/tablepro/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/datlechin/tablepro/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/datlechin/tablepro/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/datlechin/tablepro/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/datlechin/tablepro/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/datlechin/tablepro/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/datlechin/tablepro/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/datlechin/tablepro/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/datlechin/tablepro/releases/tag/v0.1.0
