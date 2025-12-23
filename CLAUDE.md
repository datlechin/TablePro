# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**OpenTable** is a native macOS database client built with **SwiftUI and AppKit**, designed as an alternative to TablePlus. The project prioritizes **Apple-native frameworks and system libraries** over custom re‑implementations wherever possible.

Supported databases:

* MySQL / MariaDB
* PostgreSQL
* SQLite

## Core Principle: Prefer Native Over Custom

When modifying or adding code, **always prefer native macOS, Swift, and system-provided solutions** instead of building custom abstractions or utilities.

**Examples:**

* Use **SwiftUI / AppKit APIs** instead of custom UI frameworks
* Use **Foundation, Combine, Swift Concurrency** instead of custom threading/event systems
* Use **native database client libraries** (libpq, MariaDB Connector/C, SQLite) instead of reimplementing protocols
* Use **Keychain, UserDefaults, NotificationCenter** instead of custom persistence or event buses

Only introduce custom implementations when:

1. A native API does not exist
2. A native API is insufficient for required performance or functionality
3. A custom layer is required to unify multiple native backends

## Build Commands

```bash
# Build from command line
xcodebuild -project OpenTable.xcodeproj -scheme OpenTable -configuration Debug build

# Run in Xcode
# Open OpenTable.xcodeproj and press Cmd+R
```

### Prerequisites
- macOS 14.0+, Xcode 15.0+
- `brew install mariadb-connector-c` (for MySQL/MariaDB compilation)
- `brew install libpq` (for PostgreSQL compilation)

## Architecture

### Core Layer (`OpenTable/Core/`)

#### Database Drivers (Thin Abstraction Over Native Libraries)

* `DatabaseDriver` protocol defines a **minimal interface** over native clients
* `DatabaseDriverFactory` selects the appropriate driver based on `DatabaseType`
* Implementations:

  * `MySQLDriver` → MariaDB Connector/C
  * `PostgreSQLDriver` → libpq
  * `SQLiteDriver` → SQLite C API

> Drivers should remain **thin adapters**, delegating real work to native libraries without duplicating logic.

#### Shared Managers (System-Aligned Singletons)

* `DatabaseManager.shared`

  * Manages active connection sessions
  * Coordinates query execution using native concurrency

* `ConnectionStorage.shared`

  * Persists connections via **Keychain and UserDefaults**

* `SSHTunnelManager.shared`

  * Uses system SSH tooling and APIs where possible

### Models (`OpenTable/Models/`)

Models are **pure data structures** with minimal logic:

* `DatabaseConnection` – Connection configuration (including SSH)
* `ConnectionSession` – Active session state
* `QueryResult` / `QueryTab` – Query execution state
* `DataChange` – Tracks pending edits for batch commits

Avoid embedding UI or persistence logic inside models.

## UI Architecture

### Native UI First: SwiftUI + AppKit

OpenTable uses **SwiftUI** as the primary UI framework, with **AppKit bridges** only where native SwiftUI controls are insufficient.

#### AppKit Bridges (Only When Necessary)

* `SQLEditorView` → wraps `NSTextView` for:

  * Syntax highlighting
  * Advanced text editing

* `DataGridView` → wraps `NSTableView` for:

  * High‑performance tabular rendering

Bridges should:

* Expose native controls directly
* Avoid re‑implementing behaviors already provided by AppKit

### View Hierarchy

* `ContentView` – Root view using `NavigationSplitView`
* `MainContentView` – Query editor or table view
* `SidebarView` – Database/table browser

## Event & Command System

The app relies on **NotificationCenter and native menu commands** instead of custom event buses.

Standard notifications:

* `.newConnection`
* `.newTab`
* `.closeCurrentTab`
* `.saveChanges`
* `.refreshData`
* `.executeQuery`
* `.databaseDidConnect`

Prefer:

* `NotificationCenter`
* SwiftUI `.commands`
* `@Environment` and bindings

over custom messaging systems.

## SQL Autocomplete System (`Core/Autocomplete/`)

Autocomplete is layered but native‑friendly:

* `SQLContextAnalyzer` – Lightweight query context parsing
* `SQLCompletionProvider` – Provides suggestions
* `SQLSchemaProvider` – Uses native driver metadata
* `SQLKeywords` – Static keyword definitions

Parsing should remain **non‑blocking and incremental**, using Swift concurrency.

## Key Patterns

### 1. Session‑Based Connections

Each database connection creates a `ConnectionSession` stored in:

```swift
DatabaseManager.activeSessions
```

Sessions preserve state when switching connections.

### 2. SwiftUI Binding Pattern

Views interact with session state via bindings backed by:

```swift
DatabaseManager.updateSession()
```

Avoid custom state containers.

### 3. Native Change Tracking

* Cell edits tracked as `DataChange`
* Highlighted via SwiftUI/AppKit
* Batch‑committed using generated SQL

No custom diffing engines unless unavoidable.

## Keyboard Shortcuts

All keyboard shortcuts are centralized in `Core/KeyboardShortcuts.swift` following macOS Human Interface Guidelines.

### Key Files
* `Core/KeyboardShortcuts.swift` - Centralized shortcut definitions and key codes
* `OpenTableApp.swift` - Menu command handlers using KeyboardShortcuts enum

### Standard macOS Shortcuts (following HIG):
* `⌘N` → New connection
* `⌘T` → New tab  
* `⌘W` → Close tab
* `⌘S` → Save changes
* `⌘R` → Refresh data
* `⌘Z` / `⌘⇧Z` → Undo / Redo
* `⌘X` / `⌘C` / `⌘V` → Cut / Copy / Paste
* `⌘A` → Select All
* `⌘F` → Toggle filters
* `Escape` → Clear selection

### Application-Specific:
* `⌘↩` → Execute query
* `⌘I` → Add row
* `⌘D` → Duplicate row
* `⌘B` → Toggle table browser
* `⌘⇧H` → Toggle history
* `⌃Space` → Trigger autocomplete

## Summary Rule

> **If macOS or Swift provides a solution, use it.**
> Build custom code only to connect, adapt, or unify native functionality — never to replace it.
