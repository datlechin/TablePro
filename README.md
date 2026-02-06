<p align="center">
  <img src="opentable.nqd.vn/docs/logo/logo.png" width="128" height="128" alt="OpenTable">
</p>

<h1 align="center">OpenTable</h1>

<p align="center">
  A fast, native macOS database client — built with SwiftUI and AppKit.
</p>

<p align="center">
  <a href="https://opentable.nqd.vn/docs">Documentation</a> ·
  <a href="https://github.com/datlechin/opentable/releases">Download</a> ·
  <a href="https://github.com/datlechin/opentable/issues">Report Bug</a>
</p>

---

<p align="center">
  <img src="opentable.nqd.vn/src/assets/app-dark.png" alt="OpenTable Screenshot" width="800">
</p>

## About

OpenTable is a lightweight alternative to TablePlus, built entirely with Apple-native frameworks. No Electron, no web views — just pure SwiftUI + AppKit for a truly native macOS experience.

**Zero third-party Swift packages.** Only system-level database libraries (libpq, libmariadb) and macOS built-in SQLite.

## Supported Databases

| Database   | Library             | Default Port |
| ---------- | ------------------- | :----------: |
| MySQL      | MariaDB Connector/C |     3306     |
| MariaDB    | MariaDB Connector/C |     3306     |
| PostgreSQL | libpq               |     5432     |
| SQLite     | Built-in macOS      |      —       |

## Features

### SQL Editor

- Syntax highlighting (keywords, strings, numbers, comments, functions)
- Line numbers and current line highlighting
- Multi-query execution (single, selected, or all)
- Multiple query tabs with persistence
- Context-aware autocomplete (tables, columns, functions, keywords)

### Data Grid

- High-performance grid optimized for large datasets (10k+ rows)
- Inline cell editing with type-aware editors
- Column sorting, resizing, and auto-fit
- Server-side and client-side pagination
- Copy as text, CSV, TSV, or JSON

### Change Tracking

- Full undo/redo for data edits
- Visual diff of pending changes
- Batch commit with generated INSERT/UPDATE/DELETE statements
- Parameterized queries to prevent SQL injection

### Table Structure Editor

- Visual column, index, and foreign key management
- Schema change preview before applying
- DDL viewer for CREATE TABLE statements
- Undo/redo for schema modifications

### Filtering

- Visual filter builder with multiple conditions (AND/OR)
- Operators: `=`, `!=`, `>`, `<`, `LIKE`, `IN`, `BETWEEN`, `IS NULL`, and more
- Quick search across all columns
- Saveable filter presets

### Import & Export

- **Export**: CSV, JSON, SQL (with optional CREATE TABLE, batching, compression)
- **Import**: CSV, JSON, SQL (with transaction support, error handling)
- Progress tracking and cancellation
- Gzip compression/decompression support

### SSH Tunneling

- Built-in SSH tunnel manager
- Password and private key authentication (RSA/Ed25519)
- Reads `~/.ssh/config` automatically
- Auto-selects available local ports

### Other

- Query history with full-text search (`Cmd+Y`)
- Database explorer sidebar with table operations (truncate, drop, rename, duplicate)
- Connection tagging and color coding
- Secure credential storage via macOS Keychain
- Customizable appearance (themes, accent colors, editor font/size)
- Table creation wizard with templates
- Universal binary (Apple Silicon + Intel)

## Requirements

- macOS 15.0 (Sequoia) or later

## Building from Source

### Prerequisites

```bash
brew install libpq mariadb-connector-c
```

### Build

```bash
# Debug build
xcodebuild -project OpenTable.xcodeproj -scheme OpenTable -configuration Debug build

# Release build (Apple Silicon)
scripts/build-release.sh arm64

# Release build (Universal)
scripts/build-release.sh both

# Create DMG
scripts/create-dmg.sh
```

### Lint & Format

```bash
swiftlint lint
swiftformat .
```

## Keyboard Shortcuts

| Shortcut          | Action                |
| ----------------- | --------------------- |
| `Cmd+Enter`       | Execute current query |
| `Cmd+Shift+Enter` | Execute all queries   |
| `Cmd+Y`           | Toggle query history  |
| `Cmd+C`           | Copy selected rows    |
| `Cmd+Shift+C`     | Copy as CSV           |
| `Cmd+Option+C`    | Copy as JSON          |

## Documentation

Full documentation is available at [opentable.nqd.vn/docs](https://opentable.nqd.vn/docs).

## License

This project is licensed under the MIT License.
