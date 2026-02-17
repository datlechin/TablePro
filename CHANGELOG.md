# Changelog

All notable changes to TablePro will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Tab reuse setting — opt-in option in Settings > Tabs to reuse clean table tabs when clicking a new table in the sidebar (off by default)
- Structure view: full undo/redo support (⌘Z / ⇧⌘Z) for all column, index, and foreign key operations
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

### Changed

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

### Removed

- Deleted unused `StructureTableCoordinator.swift` (~275 lines of dead code)

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

[Unreleased]: https://github.com/datlechin/tablepro/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/datlechin/tablepro/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/datlechin/tablepro/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/datlechin/tablepro/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/datlechin/tablepro/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/datlechin/tablepro/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/datlechin/tablepro/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/datlechin/tablepro/releases/tag/v0.1.0
