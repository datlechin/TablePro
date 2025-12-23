# OpenTable

A native macOS database client built with SwiftUI. A fast, lightweight alternative to TablePlus for managing MySQL, PostgreSQL, MariaDB, and SQLite databases.

## Features

### Multi-Database Support
- **MySQL** and **MariaDB** via native MariaDB Connector/C
- **PostgreSQL** via CLI integration
- **SQLite** with native libsqlite3 support

### Connection Management
- Multiple saved connection profiles
- Secure credential storage using macOS Keychain
- Connection testing before save
- SSH tunnel support

### Query Editor
- SQL syntax highlighting (keywords, strings, numbers, comments)
- Multi-tab query interface with query and table tabs
- Execute queries with `Cmd+Enter`
- Query-at-cursor execution (runs only the statement at cursor position)

### SQL Autocomplete
- Context-aware suggestions based on query position
- Table and column name completion with alias support
- 50+ SQL functions organized by category (aggregate, date/time, string, numeric)
- SQL snippets for common query patterns
- Keyboard navigation with `Up/Down/Enter/Escape`
- Manual trigger with `Ctrl+Space`

### High-Performance Data Grid
- NSTableView-based grid for handling large datasets
- Row numbers column
- Column resizing and reordering
- Alternating row colors for readability
- Multiple row selection

### Inline Cell Editing
- Double-click to edit any cell
- NULL value display with italic gray placeholder
- Empty string and DEFAULT value support
- Modified cells highlighted with yellow background
- Context menu: Set NULL/Empty/Default, Copy value

### Change Management
- Track pending changes before commit
- Auto-generate UPDATE/INSERT/DELETE statements
- Commit all changes with `Cmd+S`
- Discard changes and restore original values

### SQL Function Support
- Recognizes datetime functions: `NOW()`, `CURRENT_TIMESTAMP()`, `CURDATE()`, etc.
- Functions execute as SQL expressions, not string literals

### Data Export
- Export to CSV with proper escaping
- Export to JSON (pretty-printed)
- Copy to clipboard as tab-separated values

### Table Structure View
- View columns with types, nullable status, and defaults
- View indexes with primary/unique indicators
- View foreign keys with ON DELETE/UPDATE rules
- Toggle between Data and Structure views

## Keyboard Shortcuts

All keyboard shortcuts follow macOS Human Interface Guidelines for consistency with native apps.

### File Menu
| Shortcut | Action |
|----------|--------|
| `⌘N` | New connection |
| `⌘T` | New tab |
| `⌘W` | Close tab |
| `⌘S` | Save/commit changes |
| `⌘R` | Refresh data |

### Edit Menu
| Shortcut | Action |
|----------|--------|
| `⌘Z` | Undo |
| `⌘⇧Z` | Redo |
| `⌘X` | Cut |
| `⌘C` | Copy |
| `⌘V` | Paste |
| `⌘A` | Select All |
| `⌘⌫` | Delete |
| `⌘I` | Add row |
| `⌘D` | Duplicate row |
| `⌥⌫` | Truncate table |
| `Escape` | Clear selection |

### View Menu
| Shortcut | Action |
|----------|--------|
| `⌘B` | Toggle table browser |
| `⌘⌥B` | Toggle inspector |
| `⌘F` | Toggle filters |
| `⌘⇧H` | Toggle history |

### Query Menu
| Shortcut | Action |
|----------|--------|
| `⌘↩` | Execute query |
| `⌘⇧L` | Format query |
| `⌃Space` | Trigger autocomplete |

### Data Grid Navigation
| Shortcut | Action |
|----------|--------|
| `↩` | Edit cell |
| `Tab` | Next cell |
| `⇧Tab` | Previous cell |
| `↑↓←→` | Navigate cells |
| `⇧↑↓` | Extend selection |

## Requirements

- macOS 14.0 or later
- Xcode 15.0 or later
- For MySQL/MariaDB: Bundled static library (no external dependencies)
- For PostgreSQL: `psql` CLI client (typically at `/opt/homebrew/bin/psql`)
- For SQLite: No additional requirements (uses native libsqlite3)

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/datlechin/OpenTable.git
   ```

2. Install MariaDB Connector/C headers (required for compilation):
   ```bash
   brew install mariadb-connector-c
   ```

3. Open `OpenTable.xcodeproj` in Xcode

4. Build and run (`Cmd+R`)

## Architecture

```
OpenTable/
├── Core/
│   ├── Autocomplete/     # SQL autocompletion system
│   ├── Database/         # Database drivers and manager
│   ├── Export/           # CSV/JSON export
│   └── Storage/          # Keychain + UserDefaults persistence
├── Models/               # Data models (Connection, QueryResult, etc.)
├── Theme/                # Theme definitions
└── Views/
    ├── Connection/       # Connection form
    ├── Editor/           # Query editor and tabs
    ├── Results/          # Data grid
    ├── Sidebar/          # Table browser
    └── Structure/        # Table structure view
```

### Design Patterns

- **Protocol-Oriented Database Layer**: `DatabaseDriver` protocol with MySQL, PostgreSQL, and SQLite implementations
- **Factory Pattern**: `DatabaseDriverFactory` creates the appropriate driver based on connection type
- **Singleton Services**: `DatabaseManager`, `ConnectionStorage`
- **NSViewRepresentable**: SwiftUI wrappers for AppKit components (NSTextView, NSTableView)

## Version History

| Version | Date | Highlights |
|---------|------|------------|
| 0.2.0 | Dec 2024 | Data grid editing, SQL function support, autocomplete |
| 0.1.0 | Dec 2024 | Initial release with core features |

## License

MIT License

## Author

Ngo Quoc Dat
