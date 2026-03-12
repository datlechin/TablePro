# Plugin Extensibility Plan

Make the plugin system fully extensible so third-party developers can ship a `.tableplugin` bundle that works without any app-side code changes. Eliminate the `DatabaseType` enum as the source of truth; move all database-specific metadata and behavior into the plugin protocols.

## Current Problem

Adding a new database (e.g., DuckDB) requires modifying **25+ files** across the main app target. Every file that switches on `DatabaseType` must be updated. The enum is closed (`CaseIterable`), making external plugins impossible.

The plugin system currently only decouples the **driver** (C bridge + query execution). Everything else is hardcoded:

- Connection form layout
- SQL dialect (keywords, quoting, escaping)
- DDL/DML generation
- Filter/autocomplete behavior
- Theme colors, icons, toolbar labels
- File extension and URL scheme handling
- Export tree structure
- Schema editor type lists

## Target Architecture

```
┌─────────────────────────────────────────────────┐
│                  TablePro App                    │
│                                                  │
│  PluginManager ←── discovers & loads plugins     │
│       │                                          │
│       ├── DriverPluginDescriptor (static meta)   │
│       │     brand color, icon, port, auth,       │
│       │     file extensions, URL schemes,        │
│       │     connection mode, capabilities,       │
│       │     column types, system schemas,        │
│       │     query language name                  │
│       │                                          │
│       ├── SQLDialectDescriptor (from plugin)     │
│       │     keywords, functions, data types,     │
│       │     identifier quote, escape rules       │
│       │                                          │
│       └── PluginDatabaseDriver (instance)        │
│             connect, query, introspect,          │
│             DDL/DML generation, pagination,      │
│             filter SQL, EXPLAIN, TRUNCATE,       │
│             FK enable/disable, view templates    │
│                                                  │
│  App UI reads from PluginManager registry        │
│  App UI renders connection fields dynamically    │
│  No switch on DatabaseType anywhere              │
└─────────────────────────────────────────────────┘
```

**Key principles:**

- Plugin is the single source of truth for all database-specific behavior
- App code is generic — iterates plugin descriptors, never switches on type
- `DatabaseType` enum becomes a string-based identifier, not a closed enum
- `ConnectionField` gains a `fieldType` discriminator for dynamic form rendering
- `DatabaseConnection` stores extra fields in `[String: String]`, not typed properties

---

## Phase 1: Plugin Descriptor Protocol

Extend `DriverPlugin` with all static metadata the app currently reads from `DatabaseType` switches.

### 1.1 — Extend `DriverPlugin` with UI/capability metadata

**File:** `Plugins/TableProPluginKit/Sources/DriverPlugin.swift`

Add these static properties (all with default implementations):

```swift
// Connection
static var requiresAuthentication: Bool { get }  // default: true
static var connectionMode: ConnectionMode { get } // default: .network
static var urlSchemes: [String] { get }           // default: []
static var fileExtensions: [String] { get }       // default: []

// UI
static var brandColorHex: String { get }          // default: "#808080"
static var queryLanguageName: String { get }      // default: "SQL"
static var editorLanguage: EditorLanguage { get } // default: .sql

// Capabilities
static var supportsForeignKeys: Bool { get }      // default: true
static var supportsSchemaEditing: Bool { get }     // default: true
static var supportsDatabaseSwitching: Bool { get } // default: true
static var supportsSchemaSwitching: Bool { get }   // default: false
static var supportsImport: Bool { get }            // default: true
static var supportsExport: Bool { get }            // default: true
static var supportsHealthMonitor: Bool { get }     // default: true

// Schema
static var systemDatabaseNames: [String] { get }  // default: []
static var systemSchemaNames: [String] { get }     // default: []
static var databaseGroupingStrategy: GroupingStrategy { get } // default: .byDatabase
static var defaultGroupName: String { get }        // default: "main"

// Column types for structure editor
static var columnTypesByCategory: [String: [String]] { get } // default: SQL standard types
```

- [ ] Define `ConnectionMode` enum: `.network`, `.fileBased`
- [ ] Define `EditorLanguage` enum: `.sql`, `.javascript`, `.bash`, `.custom(String)`
- [ ] Define `GroupingStrategy` enum: `.byDatabase`, `.bySchema`, `.flat`
- [ ] Add all properties above with default implementations
- [ ] Update all 11 existing plugins to declare their values

### 1.2 — Extend `ConnectionField` with field types

**File:** `Plugins/TableProPluginKit/Sources/ConnectionField.swift`

```swift
public enum ConnectionFieldType: String, Codable, Sendable {
    case text
    case secureText
    case number
    case stepper
    case picker
    case filePath
    case toggle
}

// Add to ConnectionField:
public let fieldType: ConnectionFieldType  // default: .text
public let options: [String]?              // for .picker type
public let range: ClosedRange<Int>?        // for .stepper type
public let fileExtensions: [String]?       // for .filePath type
```

- [ ] Add `ConnectionFieldType` enum
- [ ] Extend `ConnectionField` with `fieldType`, `options`, `range`, `fileExtensions`
- [ ] Provide backward-compatible initializer (default `fieldType: .text`)

### 1.3 — Generalize `DatabaseConnection` extra fields

**File:** `TablePro/Models/Connection/DatabaseConnection.swift`

Replace the typed optional properties with a generic dictionary:

```swift
// Remove:
var mongoReadPreference: String?
var mongoWriteConcern: String?
var redisDatabase: Int?
var mssqlSchema: String?
var oracleServiceName: String?

// Add:
var driverFields: [String: String] = [:]
```

- [ ] Add `driverFields: [String: String]` to `DatabaseConnection`
- [ ] Migrate existing per-driver fields to `driverFields` keys
- [ ] Update `Codable` conformance with migration from old keys
- [ ] Update `DatabaseDriverFactory.buildAdditionalFields` to pass `driverFields` directly
- [ ] Update `ConnectionStorage` (Keychain) if driver fields are stored there

### 1.4 — Make `DatabaseType` open (string-based)

**File:** `TablePro/Models/Connection/DatabaseConnection.swift`

Transform `DatabaseType` from a closed enum to a string-based struct:

```swift
struct DatabaseType: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    // Known types (for backward compat during migration)
    static let mysql = DatabaseType(rawValue: "MySQL")
    static let postgresql = DatabaseType(rawValue: "PostgreSQL")
    // ... etc
}
```

All computed properties (`iconName`, `defaultPort`, etc.) become lookups into `PluginManager`:

```swift
var iconName: String {
    PluginManager.shared.driverDescriptor(for: pluginTypeId)?.iconName ?? "database-icon"
}
```

- [ ] Convert `DatabaseType` from enum to struct
- [ ] Remove all switch statements from `DatabaseType`
- [ ] Add `PluginManager.driverDescriptor(for:)` lookup method
- [ ] Ensure `CaseIterable` replacement works for connection-type picker UI
- [ ] Handle unknown/unregistered types gracefully in UI

---

## Phase 2: SQL Dialect into Plugin

Move all SQL dialect knowledge from the app into the plugin.

### 2.1 — Move `SQLDialectProvider` to TableProPluginKit

**Files:**

- `Plugins/TableProPluginKit/Sources/SQLDialectDescriptor.swift` (new)
- `TablePro/Core/Services/Query/SQLDialectProvider.swift` (refactor)

```swift
// In TableProPluginKit:
public struct SQLDialectDescriptor: Sendable {
    public let identifierQuote: String          // `"` or `` ` `` or `[`
    public let keywords: [String]
    public let functions: [String]
    public let dataTypes: [String]
    public let parameterStyle: ParameterStyle   // .questionMark or .dollar
    public let likeEscapeClause: String         // " ESCAPE '\\'" or ""
    public let regexOperator: String?           // "~", "REGEXP", nil
    public let booleanLiterals: (true: String, false: String)  // ("TRUE","FALSE") or ("1","0")
    public let requiresBackslashEscaping: Bool  // MySQL/MariaDB: true
    public let supportsExplain: Bool
    public let explainPrefix: String            // "EXPLAIN", "EXPLAIN QUERY PLAN"
}

public enum ParameterStyle: String, Sendable {
    case questionMark  // ?
    case dollar        // $1, $2
}
```

Add to `DriverPlugin`:

```swift
static var sqlDialect: SQLDialectDescriptor? { get }  // nil for NoSQL
```

- [ ] Create `SQLDialectDescriptor` in TableProPluginKit
- [ ] Create `ParameterStyle` enum
- [ ] Add `sqlDialect` property to `DriverPlugin` with default
- [ ] Implement in all SQL-based plugins
- [ ] Refactor `SQLDialectFactory` to read from plugin registry
- [ ] Remove all per-database dialect structs from app target

### 2.2 — Move identifier quoting to plugin

**Files:**

- `TablePro/Models/Connection/DatabaseConnection.swift`
- `Plugins/TableProPluginKit/Sources/PluginDatabaseDriver.swift`

```swift
// In PluginDatabaseDriver:
var identifierQuote: String { get }  // default: "\""
func quoteIdentifier(_ name: String) -> String  // default impl uses identifierQuote
```

- [ ] Add `identifierQuote` and `quoteIdentifier` to `PluginDatabaseDriver`
- [ ] Provide default implementation
- [ ] Override in plugins that need special behavior (MSSQL `[brackets]`, MongoDB no-quote)
- [ ] Remove `identifierQuote` and `quoteIdentifier` from `DatabaseType`
- [ ] Update `PluginDriverAdapter` to bridge the new methods

### 2.3 — Move string escaping to plugin

**Files:**

- `TablePro/Core/Database/SQLEscaping.swift`
- `Plugins/TableProPluginKit/Sources/PluginDatabaseDriver.swift`

- [ ] Add `escapeStringLiteral(_ value: String) -> String` to `PluginDatabaseDriver`
- [ ] Default: single-quote doubling
- [ ] MySQL/MariaDB/ClickHouse override: also backslash-escape
- [ ] Remove switch from `SQLEscaping.swift`

### 2.4 — Move filter SQL to plugin

**Files:**

- `TablePro/Core/Database/FilterSQLGenerator.swift`
- `Plugins/TableProPluginKit/Sources/PluginDatabaseDriver.swift`

Properties already covered by `SQLDialectDescriptor`: `likeEscapeClause`, `regexOperator`, `booleanLiterals`, `requiresBackslashEscaping`.

Additional method:

```swift
func castColumnToText(_ column: String) -> String  // default: column (no cast)
// PostgreSQL: "column::TEXT"
// MySQL: "CAST(column AS CHAR)"
// MSSQL: "CAST(column AS NVARCHAR(MAX))"
```

- [ ] Add `castColumnToText` to `PluginDatabaseDriver`
- [ ] Refactor `FilterSQLGenerator` to read from dialect descriptor
- [ ] Remove all `DatabaseType` switches from `FilterSQLGenerator`
- [ ] Refactor `TableQueryBuilder.buildLikeCondition` similarly

### 2.5 — Move autocomplete to plugin

**Files:**

- `TablePro/Core/Autocomplete/SQLCompletionProvider.swift`

The `dataTypeKeywords()` method (5 switches, ~120 lines) and `createTable` context completions (~20 lines) should come from the plugin.

- [ ] Add `completionKeywords(for context: String) -> [String]?` to `PluginDatabaseDriver`
- [ ] Refactor `SQLCompletionProvider` to use dialect descriptor for type/keyword lists
- [ ] Remove all `DatabaseType` switches from `SQLCompletionProvider`
- [ ] `dataTypeKeywords()` reads from `sqlDialect.dataTypes`

---

## Phase 3: DML/DDL Generation into Plugin

Move all per-database SQL generation into the plugin driver.

### 3.1 — Move DML statement generation

**File:** `TablePro/Core/ChangeTracking/SQLStatementGenerator.swift`

The `generateStatements` hook already exists on `PluginDatabaseDriver`. Currently only MongoDB/Redis implement it. Move ClickHouse's `ALTER TABLE UPDATE/DELETE` into its plugin, and MSSQL/Oracle's `TOP(1)`/`ROWNUM` syntax into theirs.

```swift
// Already exists:
func generateStatements(...) -> [(statement: String, parameters: [String?])]?
```

- [ ] Implement `generateStatements` in ClickHouseDriverPlugin
- [ ] Implement `generateStatements` in MSSQLDriverPlugin
- [ ] Implement `generateStatements` in OracleDriverPlugin
- [ ] Remove ClickHouse/MSSQL/Oracle branches from `SQLStatementGenerator`
- [ ] Move `placeholder(at:)` to use `sqlDialect.parameterStyle`
- [ ] Remove all `DatabaseType` switches from `SQLStatementGenerator`

### 3.2 — Move DDL schema generation

**File:** `TablePro/Core/SchemaTracking/SchemaStatementGenerator.swift`

This is the largest file (~600 lines of per-type switches). Add schema DDL methods to `PluginDatabaseDriver`:

```swift
func generateAddColumnSQL(table: String, column: SchemaColumnDef) -> String?
func generateModifyColumnSQL(table: String, changes: ColumnChanges) -> [String]?
func generateDropColumnSQL(table: String, column: String) -> String?
func generateAddIndexSQL(table: String, index: SchemaIndexDef) -> String?
func generateDropIndexSQL(table: String, indexName: String) -> String?
func generateAddForeignKeySQL(table: String, fk: SchemaForeignKeyDef) -> String?
func generateDropForeignKeySQL(table: String, constraintName: String) -> String?
func generateModifyPrimaryKeySQL(table: String, columns: [String]) -> [String]?
```

All return `nil` by default (unsupported). Each plugin implements what it supports.

- [ ] Define `SchemaColumnDef`, `ColumnChanges`, `SchemaIndexDef`, `SchemaForeignKeyDef` transfer types in TableProPluginKit
- [ ] Add all DDL methods to `PluginDatabaseDriver` with `nil` defaults
- [ ] Implement in MySQL, PostgreSQL, MSSQL, Oracle, ClickHouse, DuckDB, SQLite plugins
- [ ] Refactor `SchemaStatementGenerator` to call plugin first, use generic SQL fallback
- [ ] Remove all `DatabaseType` switches from `SchemaStatementGenerator`

### 3.3 — Move table operations to plugin

**File:** `TablePro/Views/Main/Extensions/MainContentCoordinator+TableOperations.swift`

```swift
// Add to PluginDatabaseDriver:
func truncateTableStatements(table: String, schema: String?) -> [String]
func dropObjectStatement(name: String, type: String, cascade: Bool, schema: String?) -> String
func fkDisableStatements() -> [String]  // default: []
func fkEnableStatements() -> [String]   // default: []
```

- [ ] Add methods to `PluginDatabaseDriver` with defaults
- [ ] Implement in all plugins
- [ ] Remove `fkDisableStatements`/`fkEnableStatements` from `ImportDataSinkAdapter` (duplicate)
- [ ] Refactor `MainContentCoordinator+TableOperations` to call plugin
- [ ] Remove all `DatabaseType` switches

### 3.4 — Move query building (pagination) to plugin

**File:** `TablePro/Core/Services/Query/TableQueryBuilder.swift`

The `buildBrowseQuery`/`buildFilteredQuery`/`buildQuickSearchQuery`/`buildCombinedQuery` hooks already exist. Implement them in MSSQL and Oracle plugins to remove the hardcoded pagination branches.

```swift
// Add to PluginDatabaseDriver:
func buildPaginatedQuery(base: String, limit: Int, offset: Int) -> String
// Default: "base LIMIT limit OFFSET offset"
// MSSQL/Oracle override with FETCH NEXT syntax
```

- [ ] Add `buildPaginatedQuery` to `PluginDatabaseDriver`
- [ ] Implement `buildBrowseQuery` etc. in MSSQLDriverPlugin
- [ ] Implement `buildBrowseQuery` etc. in OracleDriverPlugin
- [ ] Remove MSSQL/Oracle helper methods from `TableQueryBuilder`
- [ ] Simplify `TableQueryBuilder` to: plugin dispatch → standard LIMIT/OFFSET

### 3.5 — Move EXPLAIN and view templates to plugin

**Files:**

- `TablePro/Views/Main/MainContentCoordinator.swift`
- `TablePro/Views/Main/MainContentCommandActions.swift`

```swift
// Add to PluginDatabaseDriver:
func explainQuery(_ sql: String) -> String?  // nil = unsupported
func createViewTemplate(name: String) -> String
func editViewTemplate(name: String, definition: String) -> String
```

- [ ] Add methods to `PluginDatabaseDriver`
- [ ] Implement in all plugins
- [ ] Refactor coordinator to call plugin
- [ ] Remove all `DatabaseType` switches from both files

---

## Phase 4: Dynamic Connection Form

Replace hardcoded form sections with plugin-driven rendering.

### 4.1 — Render `additionalConnectionFields` dynamically

**File:** `TablePro/Views/Connection/ConnectionFormView.swift`

The form currently has hardcoded sections for MongoDB (read preference picker, write concern picker), Redis (database stepper), MSSQL (schema field), Oracle (service name field). Replace with:

```swift
ForEach(plugin.additionalConnectionFields) { field in
    switch field.fieldType {
    case .text: TextField(field.label, text: binding(for: field.id))
    case .secureText: SecureField(field.label, text: binding(for: field.id))
    case .stepper: Stepper(field.label, value: intBinding(for: field.id), in: field.range!)
    case .picker: Picker(field.label, selection: binding(for: field.id)) { ... }
    case .filePath: FilePathField(label: field.label, extensions: field.fileExtensions)
    case .toggle: Toggle(field.label, isOn: boolBinding(for: field.id))
    case .number: TextField(field.label, value: intBinding(for: field.id))
    }
}
```

- [ ] Implement dynamic field rendering in `ConnectionFormView`
- [ ] Use `connectionMode` to switch between file-picker and host/port layouts
- [ ] Use `requiresAuthentication` to show/hide username/password
- [ ] Use `supportsSSH`/`supportsSSL` (from descriptor) for tab visibility
- [ ] Remove ALL hardcoded `if type == .mongodb` / `.redis` / `.mssql` / `.oracle` sections
- [ ] Update each plugin's `additionalConnectionFields` with proper `fieldType`

### 4.2 — Dynamic connection type picker

**File:** `TablePro/Views/Connection/ConnectionFormView.swift` (type selector)

Replace the static `DatabaseType.allCases` with `PluginManager.shared.availableDriverTypes`:

```swift
Picker("Type", selection: $selectedType) {
    ForEach(PluginManager.shared.availableDriverDescriptors) { descriptor in
        Label(descriptor.displayName, image: descriptor.iconName)
            .tag(descriptor.typeId)
    }
}
```

- [ ] Add `availableDriverDescriptors` to `PluginManager`
- [ ] Replace `DatabaseType.allCases` usage in connection form
- [ ] Handle "not installed" state for downloadable plugins

---

## Phase 5: Dynamic UI Metadata

Replace all remaining hardcoded UI switches with plugin lookups.

### 5.1 — Theme colors from plugin

**File:** `TablePro/Theme/Theme.swift`

- [ ] Remove all per-database static color constants
- [ ] Remove `DatabaseType.themeColor` extension
- [ ] Add `PluginManager.brandColor(for typeId: String) -> Color` that parses `brandColorHex`
- [ ] Update all call sites to use plugin lookup

### 5.2 — Toolbar labels and visibility from plugin

**Files:**

- `TablePro/Views/Toolbar/TableProToolbarView.swift`
- `TablePro/Views/Toolbar/ConnectionStatusView.swift`
- `TablePro/Views/Toolbar/ConnectionSwitcherPopover.swift`

- [ ] Replace `databaseType == .sqlite || databaseType == .duckdb` with `!descriptor.supportsDatabaseSwitching`
- [ ] Replace `databaseType == .mongodb` etc. with `descriptor.queryLanguageName`
- [ ] Replace `databaseType == .redis` toolbar hiding with `!descriptor.supportsImport`
- [ ] Replace subtitle formatting with `descriptor.connectionMode` check

### 5.3 — Export dialog from plugin

**File:** `TablePro/Views/Export/ExportDialog.swift`

- [ ] Replace per-type tree-building switch with `descriptor.databaseGroupingStrategy`
- [ ] Use `descriptor.defaultGroupName` for auto-expansion
- [ ] Use driver's `fetchSchemas()`/`fetchDatabases()` generically

### 5.4 — Database switcher from plugin

**File:** `TablePro/ViewModels/DatabaseSwitcherViewModel.swift`

- [ ] Replace `isSystemItem` per-type lists with `descriptor.systemDatabaseNames`/`systemSchemaNames`
- [ ] Replace `databaseType == .redshift` mode check with `descriptor.supportsSchemaSwitching`

### 5.5 — Type picker from plugin

**File:** `TablePro/Views/Structure/TypePickerContentView.swift`

- [ ] Replace all 5 per-type switch tables with `descriptor.columnTypesByCategory`
- [ ] Remove all `DatabaseType` switches

### 5.6 — Editor language from plugin

**Files:**

- `TablePro/Views/Editor/SQLEditorView.swift`
- `TablePro/Views/Main/Child/MainEditorContentView.swift`
- `TablePro/Views/Filter/FilterPanelView.swift`
- `TablePro/Views/Components/SQLReviewPopover.swift`

- [ ] Replace `databaseType == .mongodb ? .javascript : ...` with `descriptor.editorLanguage`
- [ ] Remove all `DatabaseType` checks for editor language

### 5.7 — File opening from plugin

**Files:**

- `TablePro/AppDelegate+FileOpen.swift`
- `TablePro/AppDelegate+ConnectionHandler.swift`

- [ ] Replace hardcoded `sqliteFileExtensions`/`duckdbFileExtensions` with plugin registry lookup
- [ ] Replace hardcoded `databaseURLSchemes` with plugin registry lookup
- [ ] Replace `handleSQLiteFile`/`handleDuckDBFile` with generic `handleDatabaseFile(_ url: URL, typeId: String)`
- [ ] At startup, query all loaded plugins for file extensions and register them

### 5.8 — AI integration from plugin

**Files:**

- `TablePro/Core/AI/AIPromptTemplates.swift`
- `TablePro/Core/AI/AISchemaContext.swift`

- [ ] Replace `databaseType == .mongodb` checks with `descriptor.queryLanguageName`/`editorLanguage`
- [ ] Remove hardcoded AI instruction strings per database type

---

## Phase 6: Remove `DatabaseType` Enum Switches

After Phases 1-5, systematically remove all remaining `switch databaseType` statements.

### Files with switches to eliminate

| File                                           | Switches          | Phase    |
| ---------------------------------------------- | ----------------- | -------- |
| `DatabaseConnection.swift`                     | 9                 | 1.4      |
| `Theme.swift`                                  | 1                 | 5.1      |
| `DatabaseDriver.swift`                         | 2                 | 2.2, 1.3 |
| `DatabaseManager.swift`                        | 3                 | 1.1, 3.3 |
| `ConnectionFormView.swift`                     | 8+                | 4.1, 4.2 |
| `SQLDialectProvider.swift`                     | 1 (factory)       | 2.1      |
| `FilterSQLGenerator.swift`                     | 5                 | 2.4      |
| `TableQueryBuilder.swift`                      | 6                 | 3.4      |
| `SQLCompletionProvider.swift`                  | 4                 | 2.5      |
| `SchemaStatementGenerator.swift`               | 8                 | 3.2      |
| `SQLStatementGenerator.swift`                  | 5                 | 3.1      |
| `SQLEscaping.swift`                            | 1                 | 2.3      |
| `SQLParameterInliner.swift`                    | 1                 | 2.1      |
| `ImportDataSinkAdapter.swift`                  | 2                 | 3.3      |
| `MainContentCoordinator.swift`                 | 5                 | 3.5      |
| `MainContentCommandActions.swift`              | 2                 | 3.5      |
| `MainContentCoordinator+TableOperations.swift` | 5                 | 3.3      |
| `MainContentCoordinator+Navigation.swift`      | 1                 | 3.4      |
| `TypePickerContentView.swift`                  | 5                 | 5.5      |
| `ExportDialog.swift`                           | 2                 | 5.3      |
| `ConnectionStatusView.swift`                   | 1                 | 5.2      |
| `ConnectionSwitcherPopover.swift`              | 1                 | 5.2      |
| `TableProToolbarView.swift`                    | 4                 | 5.2      |
| `DatabaseSwitcherViewModel.swift`              | 2                 | 5.4      |
| `ConnectionURLFormatter.swift`                 | 2                 | 5.2      |
| `AppDelegate+FileOpen.swift`                   | 3                 | 5.7      |
| `AppDelegate+ConnectionHandler.swift`          | 2                 | 5.7      |
| `ContentView.swift`                            | 3                 | 5.2      |
| `MainContentView.swift`                        | 3                 | 5.2      |
| `QueryTab.swift`                               | 2                 | 3.4      |
| `SQLReviewPopover.swift`                       | 3                 | 5.6      |
| `SQLEditorView.swift`                          | 1                 | 5.6      |
| `StructureRowProvider.swift`                   | 3                 | 5.5      |
| `TableOperationDialog.swift`                   | 3                 | 5.2      |
| `DataGridView+Editing.swift`                   | 1                 | 5.2      |
| `SessionStateFactory.swift`                    | 1                 | 5.2      |
| `AIPromptTemplates.swift`                      | 1                 | 5.8      |
| `AISchemaContext.swift`                        | 2                 | 5.8      |
| **Total**                                      | **~112 switches** |          |

---

## Phase 7: Plugin SDK and Documentation

### 7.1 — Plugin development guide

- [ ] Document `DriverPlugin` protocol with all required/optional properties
- [ ] Document `PluginDatabaseDriver` protocol with all methods
- [ ] Document `SQLDialectDescriptor` structure
- [ ] Document `ConnectionField` with field types
- [ ] Create a template plugin project
- [ ] Document build/sign/distribute workflow

### 7.2 — Plugin validation

- [ ] Add `PluginManager` validation for required descriptor properties
- [ ] Add runtime checks for malformed plugin descriptors
- [ ] Add plugin compatibility version checking

---

## Implementation Order

```
Phase 1.1  DriverPlugin descriptor properties
Phase 1.2  ConnectionField field types
    │
    ├── Phase 2.1  SQLDialectDescriptor in PluginKit
    ├── Phase 2.2  Identifier quoting in plugin
    ├── Phase 2.3  String escaping in plugin
    │
    ├── Phase 3.1  DML generation in plugins
    ├── Phase 3.2  DDL generation in plugins
    ├── Phase 3.3  Table operations in plugins
    ├── Phase 3.4  Pagination in plugins
    ├── Phase 3.5  EXPLAIN/view templates in plugins
    │
Phase 1.3  Generalize DatabaseConnection fields
Phase 1.4  Open DatabaseType (string-based)
    │
    ├── Phase 4.1  Dynamic connection form
    ├── Phase 4.2  Dynamic type picker
    │
    ├── Phase 5.1–5.8  All UI lookups from plugin
    │
Phase 6    Remove all DatabaseType switches
Phase 7    SDK docs and validation
```

Phases 2 and 3 can run in parallel once Phase 1.1 lands.
Phases 4 and 5 require Phase 1.3 + 1.4.
Phase 6 is the cleanup sweep after everything else.

---

## Files to Create

| File                                                           | Purpose                                    |
| -------------------------------------------------------------- | ------------------------------------------ |
| `Plugins/TableProPluginKit/Sources/ConnectionMode.swift`       | `.network` / `.fileBased` enum             |
| `Plugins/TableProPluginKit/Sources/EditorLanguage.swift`       | `.sql` / `.javascript` / `.bash` enum      |
| `Plugins/TableProPluginKit/Sources/GroupingStrategy.swift`     | `.byDatabase` / `.bySchema` / `.flat` enum |
| `Plugins/TableProPluginKit/Sources/SQLDialectDescriptor.swift` | Dialect metadata struct                    |
| `Plugins/TableProPluginKit/Sources/ParameterStyle.swift`       | `.questionMark` / `.dollar` enum           |
| `Plugins/TableProPluginKit/Sources/SchemaChangeTypes.swift`    | DDL transfer types                         |
| `Plugins/TableProPluginKit/Sources/ConnectionFieldType.swift`  | Field type enum                            |

## Key Files to Modify

| File                                                           | Changes                                  |
| -------------------------------------------------------------- | ---------------------------------------- |
| `Plugins/TableProPluginKit/Sources/DriverPlugin.swift`         | Add all descriptor properties            |
| `Plugins/TableProPluginKit/Sources/PluginDatabaseDriver.swift` | Add DDL, DML, filter, pagination methods |
| `Plugins/TableProPluginKit/Sources/ConnectionField.swift`      | Add `fieldType` discriminator            |
| `TablePro/Models/Connection/DatabaseConnection.swift`          | Open `DatabaseType`, generalize fields   |
| `TablePro/Core/Plugins/PluginManager.swift`                    | Add descriptor registry, lookup methods  |
| `TablePro/Core/Plugins/PluginDriverAdapter.swift`              | Bridge new protocol methods              |
| All 11 plugin `*Plugin.swift` files                            | Implement new protocol requirements      |
