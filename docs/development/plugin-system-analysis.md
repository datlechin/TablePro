# TablePro Plugin System — Full Source Analysis

> Generated: 2026-03-11 | Covers all 9 database plugins + framework + infrastructure

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [TableProPluginKit Framework](#tablepropluginkit-framework)
3. [Plugin Loading Infrastructure](#plugin-loading-infrastructure)
4. [Host App Driver Layer](#host-app-driver-layer)
5. [All Database Plugins](#all-database-plugins)
6. [Query Building & Change Tracking](#query-building--change-tracking)
7. [Supporting Infrastructure](#supporting-infrastructure)
8. [Cross-Plugin Comparison Matrix](#cross-plugin-comparison-matrix)
9. [Known Gaps & Future Work](#known-gaps--future-work)
10. [File Reference](#file-reference)

---

## Architecture Overview

```
Views / Coordinators
        │
  DatabaseManager          (session lifecycle, connection pool, health monitoring)
        │
  DatabaseDriver protocol  (internal app interface)
        │
  PluginDriverAdapter      (bridge layer — type conversion, status tracking)
        │
  PluginDatabaseDriver     (plugin-facing interface, in TableProPluginKit)
        │
  Concrete Plugin Driver   (e.g., MySQLPluginDriver, MongoDBPluginDriver)
        │
  C Bridge / SPM Package   (e.g., CMariaDB, CLibPQ, OracleNIO)
```

**Plugin bundles** (`.tableplugin`) are loaded at runtime from:

1. `Bundle.main.builtInPlugInsURL` — app's `Contents/PlugIns/`
2. `~/Library/Application Support/TablePro/Plugins/` — user-installed

---

## TableProPluginKit Framework

Shared framework embedded in every plugin bundle. Defines all cross-boundary contracts.

### Protocol Hierarchy

#### `TableProPlugin` — root protocol

| Property/Method     | Type                          | Default  |
| ------------------- | ----------------------------- | -------- |
| `pluginName`        | `String` (static)             | required |
| `pluginVersion`     | `String` (static)             | required |
| `pluginDescription` | `String` (static)             | required |
| `capabilities`      | `[PluginCapability]` (static) | required |
| `dependencies`      | `[String]` (static)           | `[]`     |

#### `DriverPlugin: TableProPlugin` — database driver factory

| Property/Method              | Type                           | Default  |
| ---------------------------- | ------------------------------ | -------- |
| `databaseTypeId`             | `String` (static)              | required |
| `databaseDisplayName`        | `String` (static)              | required |
| `iconName`                   | `String` (static)              | required |
| `defaultPort`                | `Int` (static)                 | required |
| `additionalConnectionFields` | `[ConnectionField]` (static)   | `[]`     |
| `additionalDatabaseTypeIds`  | `[String]` (static)            | `[]`     |
| `driverVariant(for:)`        | `String?` (static)             | `nil`    |
| `createDriver(config:)`      | `any PluginDatabaseDriver`     | required |
| `requiresAuthentication`     | `Bool` (static)                | `true`   |
| `connectionMode`             | `ConnectionMode` (static)      | `.network` |
| `urlSchemes`                 | `[String]` (static)            | `[]`     |
| `fileExtensions`             | `[String]` (static)            | `[]`     |
| `brandColorHex`              | `String` (static)              | `"#808080"` |
| `queryLanguageName`          | `String` (static)              | `"SQL"`  |
| `editorLanguage`             | `EditorLanguage` (static)      | `.sql`   |
| `supportsForeignKeys`        | `Bool` (static)                | `true`   |
| `supportsSchemaEditing`      | `Bool` (static)                | `true`   |
| `supportsDatabaseSwitching`  | `Bool` (static)                | `true`   |
| `supportsSchemaSwitching`    | `Bool` (static)                | `false`  |
| `supportsImport`             | `Bool` (static)                | `true`   |
| `supportsExport`             | `Bool` (static)                | `true`   |
| `supportsHealthMonitor`      | `Bool` (static)                | `true`   |
| `systemDatabaseNames`        | `[String]` (static)            | `[]`     |
| `systemSchemaNames`          | `[String]` (static)            | `[]`     |
| `databaseGroupingStrategy`   | `GroupingStrategy` (static)    | `.byDatabase` |
| `defaultGroupName`           | `String` (static)              | `"main"` |
| `columnTypesByCategory`      | `[String: [String]]` (static)  | 7-category dict (Integer, Float, String, Date, Binary, Boolean, JSON) |

#### `ExportFormatPlugin: TableProPlugin` — export format

| Property/Method                                                     | Default                     |
| ------------------------------------------------------------------- | --------------------------- |
| `formatId`, `formatDisplayName`, `defaultFileExtension`, `iconName` | required                    |
| `supportedDatabaseTypeIds`, `excludedDatabaseTypeIds`               | `[]`                        |
| `perTableOptionColumns`                                             | `[]`                        |
| `export(tables:dataSource:destination:progress:)`                   | required                    |
| `defaultTableOptionValues()`                                        | `[]`                        |
| `isTableExportable(optionValues:)`                                  | `true`                      |
| `currentFileExtension`                                              | `Self.defaultFileExtension` |
| `warnings: [String]`                                                | `[]`                        |

#### `ImportFormatPlugin: TableProPlugin` — import format

| Property/Method                                                       | Default  |
| --------------------------------------------------------------------- | -------- |
| `formatId`, `formatDisplayName`, `acceptedFileExtensions`, `iconName` | required |
| `supportedDatabaseTypeIds`, `excludedDatabaseTypeIds`                 | `[]`     |
| `performImport(source:sink:progress:)`                                | required |

#### `SettablePluginDiscoverable` — type-erased settings witness

| Property/Method  | Default |
| ---------------- | ------- |
| `settingsView()` | —       |

Runtime-discoverable via `as? any SettablePluginDiscoverable` (needed because `SettablePlugin` has an associated type).

#### `SettablePlugin: SettablePluginDiscoverable` — unified settings protocol

| Property/Method              | Default                                                |
| ---------------------------- | ------------------------------------------------------ |
| `Settings` (associated type) | `Codable & Equatable`                                  |
| `settingsStorageId` (static) | required                                               |
| `settings`                   | required (stored var with `didSet { saveSettings() }`) |
| `settingsView()`             | `nil`                                                  |
| `loadSettings()`             | loads from `PluginSettingsStorage`                     |
| `saveSettings()`             | saves to `PluginSettingsStorage`                       |

Adopted by all 5 export plugins and SQL import plugin. Replaces the former `optionsView()` methods on `ExportFormatPlugin`/`ImportFormatPlugin` and `settingsView()` on `DriverPlugin`.

### `PluginDatabaseDriver` — Core Driver Protocol

Marked `AnyObject, Sendable`. All methods with defaults noted.

#### Connection

| Method                   | Default               |
| ------------------------ | --------------------- |
| `connect() async throws` | required              |
| `disconnect()`           | required              |
| `ping() async throws`    | `execute("SELECT 1")` |
| `serverVersion: String?` | `nil`                 |

#### Query Execution

| Method                                                                      | Default                 |
| --------------------------------------------------------------------------- | ----------------------- |
| `execute(query:) async throws -> PluginQueryResult`                         | required                |
| `fetchRowCount(query:) async throws -> Int`                                 | wraps `COUNT(*)`        |
| `fetchRows(query:offset:limit:) async throws -> PluginQueryResult`          | appends `LIMIT/OFFSET`  |
| `executeParameterized(query:parameters:) async throws -> PluginQueryResult` | inline `?` substitution |

#### Schema

| Method                                                                   | Default  |
| ------------------------------------------------------------------------ | -------- |
| `fetchTables(schema:) async throws -> [PluginTableInfo]`                 | required |
| `fetchColumns(table:schema:) async throws -> [PluginColumnInfo]`         | required |
| `fetchIndexes(table:schema:) async throws -> [PluginIndexInfo]`          | required |
| `fetchForeignKeys(table:schema:) async throws -> [PluginForeignKeyInfo]` | required |
| `fetchTableDDL(table:schema:) async throws -> String`                    | required |
| `fetchViewDefinition(view:schema:) async throws -> String`               | required |
| `fetchTableMetadata(table:schema:) async throws -> PluginTableMetadata`  | required |
| `fetchDatabases() async throws -> [String]`                              | required |
| `fetchDatabaseMetadata(_:) async throws -> PluginDatabaseMetadata`       | required |

#### Schema Navigation

| Method                                    | Default |
| ----------------------------------------- | ------- |
| `supportsSchemas: Bool`                   | `false` |
| `fetchSchemas() async throws -> [String]` | `[]`    |
| `switchSchema(to:) async throws`          | no-op   |
| `currentSchema: String?`                  | `nil`   |

#### Transactions

| Method                               | Default               |
| ------------------------------------ | --------------------- |
| `supportsTransactions: Bool`         | `true`                |
| `beginTransaction() async throws`    | `execute("BEGIN")`    |
| `commitTransaction() async throws`   | `execute("COMMIT")`   |
| `rollbackTransaction() async throws` | `execute("ROLLBACK")` |

#### Execution Control

| Method                               | Default |
| ------------------------------------ | ------- |
| `cancelQuery() throws`               | no-op   |
| `applyQueryTimeout(_:) async throws` | no-op   |

#### Batch Operations (all have defaults)

| Method                                    | Default                |
| ----------------------------------------- | ---------------------- |
| `fetchApproximateRowCount(table:schema:)` | `nil`                  |
| `fetchAllColumns(schema:)`                | N+1 loop               |
| `fetchAllForeignKeys(schema:)`            | N+1 loop               |
| `fetchAllDatabaseMetadata()`              | N+1 loop               |
| `fetchDependentTypes(table:schema:)`      | `[]`                   |
| `fetchDependentSequences(table:schema:)`  | `[]`                   |
| `createDatabase(name:charset:collation:)` | throws "not supported" |
| `switchDatabase(to:)`                     | throws "not supported" |

#### NoSQL Query Building (all default `nil` — SQL plugins leave unimplemented)

| Method                                                                                                              |
| ------------------------------------------------------------------------------------------------------------------- |
| `buildBrowseQuery(table:sortColumns:columns:limit:offset:) -> String?`                                              |
| `buildFilteredQuery(table:filters:logicMode:sortColumns:columns:limit:offset:) -> String?`                          |
| `buildQuickSearchQuery(table:searchText:columns:sortColumns:limit:offset:) -> String?`                              |
| `buildCombinedQuery(table:filters:logicMode:searchText:searchColumns:sortColumns:columns:limit:offset:) -> String?` |

#### Statement Generation (default `nil` — NoSQL plugins override)

| Method                                                                                                                                             |
| -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `generateStatements(table:columns:changes:insertedRowData:deletedRowIndices:insertedRowIndices:) -> [(statement: String, parameters: [String?])]?` |

### Transfer Types

| Type                     | Key Fields                                                                                                   |
| ------------------------ | ------------------------------------------------------------------------------------------------------------ |
| `PluginQueryResult`      | `columns`, `columnTypeNames`, `rows: [[String?]]`, `rowsAffected`, `executionTime`, `isTruncated`            |
| `PluginColumnInfo`       | `name`, `dataType`, `isNullable`, `isPrimaryKey`, `defaultValue`, `extra`, `charset`, `collation`, `comment` |
| `PluginTableInfo`        | `name`, `type` ("TABLE"/"VIEW"), `rowCount`                                                                  |
| `PluginTableMetadata`    | `tableName`, `dataSize`, `indexSize`, `totalSize`, `rowCount`, `comment`, `engine`                           |
| `PluginDatabaseMetadata` | `name`, `tableCount`, `sizeBytes`, `isSystemDatabase`                                                        |
| `PluginForeignKeyInfo`   | `name`, `column`, `referencedTable`, `referencedColumn`, `onDelete`, `onUpdate`                              |
| `PluginIndexInfo`        | `name`, `columns`, `isUnique`, `isPrimary`, `type`                                                           |
| `DriverConnectionConfig` | `host`, `port`, `username`, `password`, `database`, `additionalFields: [String: String]`                     |
| `ConnectionField`            | `id`, `label`, `placeholder`, `isRequired`, `defaultValue`, `fieldType: FieldType`, `isSecure` (computed from fieldType) |
| `ConnectionField.FieldType`  | enum: `.text`, `.secure`, `.dropdown(options:)`                                                                           |
| `ConnectionField.DropdownOption` | `value`, `label`                                                                                                      |
| `PluginRowChange`        | `rowIndex`, `type (.insert/.update/.delete)`, `cellChanges`, `originalRow`                                   |
| `PluginCapability`       | enum: `.databaseDriver`, `.exportFormat`, `.importFormat`                                                    |
| `PluginRowLimits`        | `defaultMax = 100_000` (static constant)                                                                     |
| `ConnectionMode`              | enum: `.network`, `.fileBased`                                                                                |
| `EditorLanguage`              | enum: `.sql`, `.javascript`, `.bash`, `.custom(String)`                                                       |
| `GroupingStrategy`            | enum: `.byDatabase`, `.bySchema`, `.flat`                                                                     |
| `PluginExportTable`           | `name`, `databaseName`, `tableType`, `optionValues`, `qualifiedName`                                          |
| `PluginExportOptionColumn`    | `id`, `label`, `width`, `defaultValue`                                                                        |
| `PluginExportError`           | enum: `.fileWriteFailed`, `.encodingFailed`, `.compressionFailed`, `.exportFailed`                             |
| `PluginExportCancellationError` | empty struct, `Error + LocalizedError`                                                                      |
| `PluginSequenceInfo`          | `name`, `ddl`                                                                                                 |
| `PluginEnumTypeInfo`          | `name`, `labels: [String]`                                                                                    |
| `PluginImportResult`          | `executedStatements`, `executionTime`, `failedStatement?`, `failedLine?`                                      |
| `PluginImportError`           | enum: `.statementFailed`, `.rollbackFailed`, `.cancelled`, `.importFailed`                                    |
| `PluginImportCancellationError` | empty struct, `Error + LocalizedError`                                                                      |

### Error Protocol

`PluginDriverError` — plugins conform their errors:

- `pluginErrorMessage: String`
- `pluginErrorCode: Int?` (default: `nil`)
- `pluginSqlState: String?` (default: `nil`)
- `pluginErrorDetail: String?` (default: `nil`)

### Concurrency Helpers

`PluginConcurrencySupport.swift` — bridges blocking C library calls to Swift concurrency:

- `pluginDispatchAsync(on:execute:) async throws -> T`
- `pluginDispatchAsync(on:execute:) async throws` (void)
- `pluginDispatchAsyncCancellable(on:cancellationCheck:execute:) async throws -> T`

### Shared Utilities

- `PluginSettingsStorage` — namespaced `UserDefaults` (`com.TablePro.plugin.<pluginId>.<key>`)
- `PluginExportUtilities` — `escapeJSONString`, `createFileHandle`, `sanitizeForSQLComment`
- `MongoShellParser` — parses MongoDB shell syntax into `MongoOperation` cases
- `ArrayExtension` — `subscript(safe:)` on `Array`

---

## Plugin Loading Infrastructure

### PluginManager (`Core/Plugins/PluginManager.swift`)

`@MainActor @Observable` singleton. Central registry.

**State:**

- `plugins: [PluginEntry]` — all discovered metadata
- `driverPlugins: [String: any DriverPlugin]` — keyed by `databaseTypeId`
- `exportPlugins: [String: any ExportFormatPlugin]` — keyed by `formatId`
- `importPlugins: [String: any ImportFormatPlugin]` — keyed by `formatId`
- `disabledPluginIds: Set<String>` — persisted to `UserDefaults`
- `pluginInstances: [String: any TableProPlugin]` — all loaded plugin instances
- `needsRestart: Bool` — true after uninstall
- `isInstalling: Bool` — true during installation

**Two-phase loading:**

1. **`discoverAllPlugins()`** (synchronous, at launch) — scans both directories for `.tableplugin` bundles, reads `Info.plist` for version checks (`TableProPluginKitVersion`, `TableProMinAppVersion`). User-installed plugins: verifies code signature against Team ID `D7HJ5TFYCU`.
2. **`loadPendingPlugins()`** (async, deferred to next run loop) — calls `bundle.load()`, reads `principalClass`, casts to `TableProPlugin.Type`, calls `registerCapabilities`.

**Capability registration:** Pattern-matches on protocol conformance (`DriverPlugin`, `ExportFormatPlugin`, `ImportFormatPlugin`).

**Plugin installation:** ZIP extraction via `/usr/bin/ditto -xk`, signature verification, copy to user plugins dir. Registry support: download via `RegistryClient`, SHA-256 checksum verification.

**`currentPluginKitVersion = 1`** — rejects plugins declaring a higher version.

### PluginEntry (`Core/Plugins/PluginModels.swift`)

Lightweight metadata: `id` (bundle identifier), `bundle`, `url`, `source` (.builtIn/.userInstalled), `name`, `version`, `capabilities`, `isEnabled`.

### PluginError (`Core/Plugins/PluginError.swift`)

Cases: `invalidBundle`, `signatureInvalid`, `checksumMismatch`, `incompatibleVersion`, `appVersionTooOld`, `cannotUninstallBuiltIn`, `notFound`, `noCompatibleBinary`, `installFailed`, `pluginConflict`, `downloadFailed`, `pluginNotInstalled`, `incompatibleWithCurrentApp`.

---

## Host App Driver Layer

### DatabaseDriver Protocol (`Core/Database/DatabaseDriver.swift`)

Internal interface mirroring `PluginDatabaseDriver` but using app-side types (`QueryResult`, `ColumnInfo`, etc.). Key additions beyond plugin protocol:

- `var connection: DatabaseConnection { get }`
- `var status: ConnectionStatus { get }`
- `func testConnection() async throws -> Bool` (connect + disconnect)
- `var noSqlPluginDriver: (any PluginDatabaseDriver)?` (default: `nil`)

**`SchemaSwitchable`** sub-protocol: `currentSchema`, `escapedSchema`, `switchSchema(to:)`.

### DatabaseDriverFactory (`DatabaseDriver.swift`)

Static method: `createDriver(for connection: DatabaseConnection) throws -> DatabaseDriver`.

**Lookup chain:**

1. `connection.type.pluginTypeId` → `PluginManager.shared.driverPlugins[...]`
2. Fallback: `loadPendingPlugins()` safety call
3. Build `DriverConnectionConfig` (password from Keychain, SSL fields, type-specific extras)
4. `plugin.createDriver(config:)` → `PluginDatabaseDriver`
5. Wrap in `PluginDriverAdapter(connection:pluginDriver:)` → return

### PluginDriverAdapter (`Core/Plugins/PluginDriverAdapter.swift`)

Bridges `PluginDatabaseDriver` → `DatabaseDriver`. Conforms to both `DatabaseDriver` and `SchemaSwitchable`.

Key behaviors:

- **Status tracking:** Owns `status: ConnectionStatus`, sets `.connecting`/`.connected`/`.error` around plugin calls
- **NoSQL detection:** Probes `buildBrowseQuery(table: "_probe", ...)` — non-nil = NoSQL plugin handles query building
- **`mapQueryResult`:** Converts `PluginQueryResult` → `QueryResult`, maps type name strings to `ColumnType` enum via uppercased prefix/suffix matching
- **Schema context:** Passes `pluginDriver.currentSchema` as `schema:` to all schema-related calls

### DatabaseManager (`Core/Database/DatabaseManager.swift`)

`@MainActor @Observable` singleton managing sessions.

**State:**

- `activeSessions: [UUID: ConnectionSession]`
- `currentSessionId: UUID?`
- `healthMonitors: [UUID: ConnectionHealthMonitor]`
- `connectionListVersion: Int` — incremented on connection list changes
- `connectionStatusVersion: Int` — incremented on status changes

**Connection flow:**

1. Check for existing session → switch to it
2. SSH tunnel if needed (`SSHTunnelManager`)
3. `DatabaseDriverFactory.createDriver(for:)` → `PluginDriverAdapter`
4. `driver.connect()`, `applyQueryTimeout()`, `executeStartupCommands()`
5. Schema/database initialization per driver type
6. `startHealthMonitor(for:)` (skipped for SQLite/DuckDB)

**Health monitoring (`ConnectionHealthMonitor`):**

- 30s ping interval
- Exponential backoff reconnect: initial `[2, 4, 8]s`, doubles up to `120s` cap
- Random 0–10s initial stagger across multiple connections

---

## All Database Plugins

### 1. MySQLDriverPlugin — MySQL / MariaDB

| Attribute        | Value                                                   |
| ---------------- | ------------------------------------------------------- |
| **Entry**        | `Plugins/MySQLDriverPlugin/MySQLPlugin.swift`           |
| **Driver**       | `MySQLPluginDriver` (618 lines)                         |
| **Connection**   | `MariaDBPluginConnection` (822 lines)                   |
| **C Bridge**     | `CMariaDB` → `libmariadb.a`                             |
| **DB Types**     | MySQL (primary) + MariaDB (`additionalDatabaseTypeIds`) |
| **Default Port** | 3306                                                    |
| **File Count**   | 4 Swift + C bridge                                      |

**Implemented methods (overriding defaults):**

- `connect`, `disconnect`, `ping`
- `execute` (with auto-reconnect on error codes 2006/2013/2055)
- `executeParameterized` — native `mysql_stmt_*` prepared statements
- `cancelQuery` — opens 2nd connection, sends `KILL QUERY <thread_id>`
- `applyQueryTimeout` — detects MariaDB vs MySQL (`max_statement_time` vs `max_execution_time`)
- `fetchTables`, `fetchColumns`, `fetchAllColumns`
- `fetchIndexes`, `fetchForeignKeys`, `fetchAllForeignKeys`
- `fetchApproximateRowCount` — `information_schema.TABLES.TABLE_ROWS`
- `fetchTableDDL`, `fetchViewDefinition`, `fetchTableMetadata`
- `fetchDatabases`, `fetchDatabaseMetadata`, `fetchAllDatabaseMetadata`
- `createDatabase` — charset whitelist validation
- `switchDatabase` — `` USE `db` ``
- `beginTransaction` — `START TRANSACTION`
- `fetchRowCount`, `fetchRows` — strip existing LIMIT/OFFSET

**Unique:** GEOMETRY WKB→WKT parser, ENUM/SET flag detection from wire protocol, native prepared statements.

**Transactions:** Yes | **Schemas:** No

---

### 2. PostgreSQLDriverPlugin — PostgreSQL / Redshift

| Attribute        | Value                                                         |
| ---------------- | ------------------------------------------------------------- |
| **Entry**        | `Plugins/PostgreSQLDriverPlugin/PostgreSQLPlugin.swift`       |
| **Driver (PG)**  | `PostgreSQLPluginDriver` (744 lines)                          |
| **Driver (RS)**  | `RedshiftPluginDriver` (652 lines)                            |
| **Connection**   | `LibPQPluginConnection`                                       |
| **C Bridge**     | `CLibPQ` → `libpq.a`                                          |
| **DB Types**     | PostgreSQL (primary) + Redshift (`additionalDatabaseTypeIds`) |
| **Default Port** | 5432                                                          |
| **File Count**   | 4 Swift + C bridge                                            |

**PostgreSQL — implemented methods:**

- All standard + `supportsSchemas = true`
- `fetchSchemas` — `information_schema.schemata`, excludes `pg_%`/`information_schema`
- `switchSchema` — `SET search_path TO "schema", public`
- `fetchColumns` — complex JOIN across `pg_statio_all_tables`, `pg_description`, PK subquery; USER-DEFINED → ENUM
- `fetchTableDDL` — 3 parallel `async let` queries → reconstructed DDL
- `fetchDependentTypes` — PostgreSQL ENUM types via `pg_enum`
- `fetchDependentSequences` — sequences via `pg_sequences` + `pg_attrdef`
- `fetchApproximateRowCount` — `pg_class.reltuples`
- `cancelQuery` — `PQcancel`
- `applyQueryTimeout` — `SET statement_timeout = 'Nms'`
- `createDatabase` — charset whitelist validation

**Redshift — differences:**

- `fetchIndexes` — Redshift `pg_table_def` for DISTKEY/SORTKEY
- `fetchApproximateRowCount` — `svv_table_info.tbl_rows`
- `fetchTableDDL` — `SHOW TABLE` or `pg_attribute` + DISTKEY/SORTKEY
- `fetchTableMetadata` / `fetchDatabaseMetadata` — `svv_table_info`

**Transactions:** Yes | **Schemas:** Yes (both drivers)

---

### 3. SQLiteDriverPlugin — SQLite

| Attribute          | Value                                                       |
| ------------------ | ----------------------------------------------------------- |
| **Entry + Driver** | `Plugins/SQLiteDriverPlugin/SQLitePlugin.swift` (684 lines) |
| **Connection**     | `SQLiteConnectionActor` (Swift `actor`)                     |
| **C Bridge**       | None — macOS SDK `SQLite3`                                  |
| **Default Port**   | 0 (file-based)                                              |
| **File Count**     | 1 Swift                                                     |

**Implemented methods:**

- All standard schema/query methods
- `executeParameterized` — native `sqlite3_bind_text`/`sqlite3_bind_null`
- `cancelQuery` — `sqlite3_interrupt`
- `applyQueryTimeout` — `sqlite3_busy_timeout` (lock wait, not execution)
- `fetchAllColumns` — single query via `pragma_table_info`
- `fetchTableDDL` — `sqlite_master.sql` + DDL prettifier
- `fetchDatabases` — `[]` (N/A)
- `createDatabase` — throws unsupported

**Unique:** Actor-based concurrency, DDL formatter, file-based connection, `~` path expansion.

**Transactions:** Yes | **Schemas:** No

---

### 4. ClickHouseDriverPlugin — ClickHouse

| Attribute          | Value                                                               |
| ------------------ | ------------------------------------------------------------------- |
| **Entry + Driver** | `Plugins/ClickHouseDriverPlugin/ClickHousePlugin.swift` (868 lines) |
| **C Bridge**       | None — URLSession HTTP                                              |
| **Connection**     | HTTP POST to `http[s]://host:port/` with Basic auth                 |
| **Default Port**   | 8123                                                                |
| **File Count**     | 1 Swift                                                             |

**Implemented methods:**

- All standard + custom parameterized queries via ClickHouse HTTP param protocol (`{p1:String}`)
- `cancelQuery` — cancel URLSession task + `KILL QUERY WHERE query_id`
- `applyQueryTimeout` — `SET max_execution_time = N`
- `switchDatabase` — in-memory only
- `fetchApproximateRowCount` — `system.parts` SUM(rows)
- `fetchForeignKeys` — `[]` (ClickHouse has no FKs)
- Response parsing: `FORMAT TabSeparatedWithNamesAndTypes`, `\N` = NULL

**Unique:** HTTP-only (no C dependency), TSV parsing, self-signed cert support via `InsecureTLSDelegate`, engine type in table listing.

**Transactions:** No (`supportsTransactions = false`) | **Schemas:** No

---

### 5. MSSQLDriverPlugin — SQL Server

| Attribute             | Value                                                      |
| --------------------- | ---------------------------------------------------------- |
| **Entry + Driver**    | `Plugins/MSSQLDriverPlugin/MSSQLPlugin.swift` (1047 lines) |
| **Connection**        | `FreeTDSConnection` — TDS 7.4                              |
| **C Bridge**          | `CFreeTDS` → `libsybdb.a`                                  |
| **Additional Fields** | `mssqlSchema` (default: `dbo`)                             |
| **Default Port**      | 1433                                                       |
| **File Count**        | 1 Swift + C bridge                                         |

**Implemented methods:**

- All standard + `supportsSchemas = true`
- `executeParameterized` — `sp_executesql` with `@p1, @p2, ...` params
- `switchDatabase` — `dbuse()` via FreeTDS
- `switchSchema` — in-memory only
- `fetchTableDDL` — manual DDL reconstruction from columns + indexes + FKs
- `fetchRows` — `OFFSET N ROWS FETCH NEXT N ROWS ONLY` (T-SQL pagination)
- Global error/message handlers via NSLock-protected string

- `cancelQuery` — `FreeTDSConnection.cancelCurrentQuery()`
- `applyQueryTimeout` — `SET LOCK_TIMEOUT <ms>`

**Unique:** Multi-result set support, native NVARCHAR (UTF-16LE), `hasTopLevelOrderBy` reverse scanner.

**Transactions:** Yes | **Schemas:** Yes

---

### 6. MongoDBDriverPlugin — MongoDB

| Attribute             | Value                                                         |
| --------------------- | ------------------------------------------------------------- |
| **Entry**             | `Plugins/MongoDBDriverPlugin/MongoDBPlugin.swift`             |
| **Driver**            | `MongoDBPluginDriver` (803 lines)                             |
| **Connection**        | `MongoDBConnection` (libmongoc URI)                           |
| **C Bridge**          | `CLibMongoc` → libmongoc                                      |
| **Additional Fields** | `mongoAuthSource`, `mongoReadPreference`, `mongoWriteConcern` |
| **Default Port**      | 27017                                                         |
| **File Count**        | 6 Swift + C bridge                                            |

**Implemented methods:**

- All standard schema methods (columns inferred by sampling 500 docs)
- `execute` — parses via `MongoShellParser`, dispatches to typed operations
- `cancelQuery` — via `MongoDBConnection.cancelCurrentQuery()`
- `fetchAllColumns` — parallelized (batch size 4 via `withThrowingTaskGroup`)
- `fetchTableDDL` — JS shell code (collection options + createIndex calls)
- `fetchForeignKeys` — `[]`
- **All 4 `build*Query` methods** — delegates to `MongoDBQueryBuilder`
- **`generateStatements`** — delegates to `MongoDBStatementGenerator`

**Supported operations:** `find`, `findOne`, `aggregate`, `countDocuments`, `insertOne/Many`, `updateOne/Many`, `replaceOne`, `deleteOne/Many`, `createIndex`, `dropIndex`, `findOneAndUpdate/Replace/Delete`, `drop`, `runCommand`, `listCollections`, `listDatabases`, `ping`

**Unique:** Schema inferred by document sampling, BSON flattener for tabular display, full MQL CRUD coverage.

**Transactions:** No | **Schemas:** No

---

### 7. RedisDriverPlugin — Redis

| Attribute             | Value                                         |
| --------------------- | --------------------------------------------- |
| **Entry**             | `Plugins/RedisDriverPlugin/RedisPlugin.swift` |
| **Driver**            | `RedisPluginDriver` (~1412 lines)             |
| **Connection**        | `RedisPluginConnection` (hiredis)             |
| **C Bridge**          | `CRedis` → libhiredis                         |
| **Additional Fields** | `redisDatabase`                               |
| **Default Port**      | 6379                                          |
| **File Count**        | 6 Swift + C bridge                            |

**Implemented methods:**

- `ping` — `PING` command
- `execute` — parses via `RedisCommandParser`, dispatches to typed operations
- `cancelQuery` — via connection cancel
- `fetchTables` — `INFO keyspace` (databases = "tables")
- `fetchColumns` — hardcoded: `[Key (PK), Type, TTL, Value]`
- `fetchApproximateRowCount` — `DBSIZE`
- `fetchTableDDL` — comment block with DB info + sampled type distribution
- **All 4 `build*Query` methods** — delegates to `RedisQueryBuilder`
- **`generateStatements`** — delegates to `RedisStatementGenerator`

**Concept mapping:** databases → "tables", key-value pairs → "rows" with Key/Type/TTL/Value columns.

**Unique:** SCAN-based enumeration (avoids KEYS), pipeline support, `SELECT 1` remapped to `PING`.

**Transactions:** No | **Schemas:** No

---

### 8. OracleDriverPlugin — Oracle

| Attribute             | Value                                                       |
| --------------------- | ----------------------------------------------------------- |
| **Entry + Driver**    | `Plugins/OracleDriverPlugin/OraclePlugin.swift` (643 lines) |
| **Connection**        | `OracleConnectionWrapper` (247 lines)                       |
| **C Bridge**          | None — OracleNIO (SPM)                                      |
| **Additional Fields** | `oracleServiceName`                                         |
| **Default Port**      | 1521                                                        |
| **File Count**        | 2 Swift                                                     |

**Implemented methods:**

- All standard + `supportsSchemas = true`
- `execute` — intercepts `SELECT 1` → `SELECT 1 FROM DUAL`
- `beginTransaction` — no-op (Oracle implicit transactions)
- `fetchRows` — `OFFSET N ROWS FETCH NEXT N ROWS ONLY` (Oracle 12c+)
- `fetchSchemas` = `fetchDatabases` = `ALL_USERS` (Oracle schemas = users)
- `switchSchema` — `ALTER SESSION SET CURRENT_SCHEMA`
- `fetchTableDDL` — `DBMS_METADATA.GET_DDL` with manual fallback
- `fetchAllColumns`, `fetchAllForeignKeys` — bulk queries

**Unique:** Pure Swift NIO client, multi-strategy cell decoding, implicit transactions, `DBMS_METADATA.GET_DDL`.

**Not implemented:** `cancelQuery` (default no-op — OracleNIO has no cancel API).

**Transactions:** Implicit (no BEGIN needed) | **Schemas:** Yes

---

### 9. DuckDBDriverPlugin — DuckDB

| Attribute          | Value                                                       |
| ------------------ | ----------------------------------------------------------- |
| **Entry + Driver** | `Plugins/DuckDBDriverPlugin/DuckDBPlugin.swift` (908 lines) |
| **Connection**     | `DuckDBConnectionActor` (Swift `actor`)                     |
| **C Bridge**       | `CDuckDB` → DuckDB C API                                    |
| **Default Port**   | 0 (file-based)                                              |
| **File Count**     | 1 Swift + C bridge                                          |

**Implemented methods:**

- All standard + `supportsSchemas = true` (default: `main`)
- `executeParameterized` — native `duckdb_bind_*`
- `cancelQuery` — `duckdb_interrupt`
- `fetchTableDDL` — `duckdb_tables()` first, manual fallback
- `fetchIndexes` — `duckdb_indexes()` with ART index type
- `serverVersion` — `duckdb_library_version()` at runtime
- Analytical types: HUGEINT, LIST, STRUCT, MAP, UNION, UUID, BIT

**Unique:** Auto-installs/loads extensions on connect, analytical type support, file-based like SQLite.

**Transactions:** Yes | **Schemas:** Yes

---

## Query Building & Change Tracking

### TableQueryBuilder (`Core/Services/Query/TableQueryBuilder.swift`)

Pure `struct` with `databaseType` and optional `pluginDriver`. Constructs SELECT queries for table browser.

**Plugin dispatch pattern** (all 4 query methods):

1. If `pluginDriver != nil` → call `pluginDriver.buildXxx(...)`
2. If plugin returns non-nil String → use it (MongoDB/Redis)
3. If nil → fall through to hardcoded SQL path
4. MSSQL/Oracle: `OFFSET n ROWS FETCH NEXT n ROWS ONLY`
5. Others: `LIMIT n OFFSET n`

**LIKE escaping per dialect:**
| Database | Pattern |
|---|---|
| PostgreSQL/Redshift | `column::TEXT LIKE '%x%' ESCAPE '\'` |
| MySQL/MariaDB | `CAST(column AS CHAR) LIKE '%x%'` |
| ClickHouse | `toString(column) LIKE '%x%' ESCAPE '\'` |
| DuckDB | `CAST(column AS VARCHAR) LIKE '%x%' ESCAPE '\'` |
| MSSQL | `CAST(column AS NVARCHAR(MAX)) LIKE '%x%' ESCAPE '\'` |
| Oracle | `CAST(column AS VARCHAR2(4000)) LIKE '%x%' ESCAPE '\'` |
| SQLite/MongoDB/Redis | bare `LIKE '%x%' ESCAPE '\'` |

### DataChangeManager (`Core/ChangeTracking/DataChangeManager.swift`)

`@MainActor @Observable` — central controller for in-flight data edits.

**Plugin integration in `generateSQL()`:**

1. If `pluginDriver != nil`: convert `RowChange` → `PluginRowChange`, call `pluginDriver.generateStatements(...)`
2. Non-nil result → map to `ParameterizedStatement`
3. `nil` result → fall through to `SQLStatementGenerator`
4. For MongoDB/Redis: throws if plugin driver unavailable

### SQLStatementGenerator (`Core/ChangeTracking/SQLStatementGenerator.swift`)

Placeholder syntax per database:

- PostgreSQL/Redshift/DuckDB: `$1`, `$2`, ...
- Everything else: `?`

Per-database quirks:

- MySQL/MariaDB: `UPDATE ... LIMIT 1` / `DELETE ... LIMIT 1`
- MSSQL: `UPDATE TOP (1)` / `DELETE TOP (1)`
- Oracle: `AND ROWNUM = 1`
- ClickHouse: `ALTER TABLE t UPDATE/DELETE WHERE ...`

### SQLDialectProvider (`Core/Services/Query/SQLDialectProvider.swift`)

Per-dialect keyword/function/type sets for autocomplete. Factory: `SQLDialectFactory.createDialect(for: DatabaseType)`.

| Dialect             | Databases            | `identifierQuote` |
| ------------------- | -------------------- | ----------------- |
| `MySQLDialect`      | MySQL, MariaDB       | `` ` ``           |
| `PostgreSQLDialect` | PostgreSQL, Redshift | `"`               |
| `SQLiteDialect`     | SQLite               | `` ` ``           |
| `MSSQLDialect`      | SQL Server           | `[`               |
| `OracleDialect`     | Oracle               | `"`               |
| `ClickHouseDialect` | ClickHouse           | `` ` ``           |
| `DuckDBDialect`     | DuckDB               | `"`               |

MongoDB/Redis fall back to `SQLiteDialect` (placeholder).

---

## Supporting Infrastructure

### DatabaseType Enum (`Models/Connection/DatabaseConnection.swift`)

| Case          | Raw Value      | `pluginTypeId` | Port  | `identifierQuote` |
| ------------- | -------------- | -------------- | ----- | ----------------- |
| `.mysql`      | `"MySQL"`      | `"MySQL"`      | 3306  | `` ` ``           |
| `.mariadb`    | `"MariaDB"`    | `"MySQL"`      | 3306  | `` ` ``           |
| `.postgresql` | `"PostgreSQL"` | `"PostgreSQL"` | 5432  | `"`               |
| `.sqlite`     | `"SQLite"`     | `"SQLite"`     | 0     | `` ` ``           |
| `.redshift`   | `"Redshift"`   | `"PostgreSQL"` | 5439  | `"`               |
| `.mongodb`    | `"MongoDB"`    | `"MongoDB"`    | 27017 | `"`               |
| `.redis`      | `"Redis"`      | `"Redis"`      | 6379  | `"`               |
| `.mssql`      | `"SQL Server"` | `"SQL Server"` | 1433  | `[`               |
| `.oracle`     | `"Oracle"`     | `"Oracle"`     | 1521  | `"`               |
| `.clickhouse` | `"ClickHouse"` | `"ClickHouse"` | 8123  | `` ` ``           |
| `.duckdb`     | `"DuckDB"`     | `"DuckDB"`     | 0     | `"`               |

Key computed properties: `isDownloadablePlugin`, `requiresAuthentication`, `supportsForeignKeys`, `supportsSchemaEditing`, `quoteIdentifier(_:)`.

### Connection Models (`Models/Connection/`)

- **`DatabaseConnection`** — persisted config: host, port, database, username, type, SSH/SSL configs, per-driver fields
- **`ConnectionSession`** — runtime state: driver, status, tables, selectedTables, currentSchema/Database
- **`SSHConfiguration`** — password/key/agent auth, jump hosts, 1Password socket detection
- **`SSLConfiguration`** — 5 SSL modes, CA/client cert/key paths

### Schema Models (`Models/Schema/`)

- **`EditableColumnDefinition`** — richer than `PluginColumnInfo` (adds autoIncrement, unsigned, onUpdate)
- **`EditableIndexDefinition`** — IndexType enum (BTREE, HASH, FULLTEXT, SPATIAL, GIN, GIST, BRIN)
- **`EditableForeignKeyDefinition`** — ReferentialAction enum
- **`SchemaChange`** — enum: addColumn/modifyColumn/deleteColumn + indexes + FKs + modifyPrimaryKey
- Has `isDestructive` and `requiresDataMigration` computed properties

### Export/Import Adapters

- **`ExportDataSourceAdapter`** — `DatabaseDriver` → `PluginExportDataSource`
- **`ImportDataSinkAdapter`** — `DatabaseDriver` → `PluginImportDataSink` (includes FK disable/enable per database)
- **`SqlFileImportSource`** — wraps SQL file URL with decompression + async statement streaming

---

## Cross-Plugin Comparison Matrix

| Feature                   | MySQL              | PostgreSQL              | Redshift          | SQLite        | ClickHouse         | MSSQL            | MongoDB          | Redis          | Oracle           | DuckDB          |
| ------------------------- | ------------------ | ----------------------- | ----------------- | ------------- | ------------------ | ---------------- | ---------------- | -------------- | ---------------- | --------------- |
| **Transactions**          | Yes                | Yes                     | Yes               | Yes           | No                 | Yes              | No               | No             | Implicit         | Yes             |
| **Schemas**               | No                 | Yes                     | Yes               | No            | No                 | Yes              | No               | No             | Yes              | Yes             |
| **Parameterized**         | Native stmt        | Native PQ               | Native PQ         | Native bind   | HTTP params        | sp_executesql    | N/A              | N/A            | Default fallback | Native bind     |
| **cancelQuery**           | KILL QUERY         | PQcancel                | PQcancel          | interrupt     | KILL HTTP          | FreeTDS cancel   | mongoc cancel    | hiredis cancel | no-op            | interrupt       |
| **Query Timeout**         | max_execution_time | statement_timeout       | statement_timeout | busy_timeout  | max_execution_time | SET LOCK_TIMEOUT | setQueryTimeout  | no-op          | no-op            | no-op           |
| **DB Switching**          | USE                | (reconnect)             | (reconnect)       | N/A           | in-memory          | dbuse()          | in-memory        | N/A            | N/A              | N/A             |
| **Custom Query Builder**  | No                 | No                      | No                | No            | No                 | No               | Yes              | Yes            | No               | No              |
| **Custom Stmt Generator** | No                 | No                      | No                | No            | No                 | No               | Yes              | Yes            | No               | No              |
| **Approx Row Count**      | info_schema        | pg_class                | svv_table_info    | N/A           | system.parts       | sys.partitions   | countDocuments   | DBSIZE         | N/A              | N/A             |
| **DDL Source**            | SHOW CREATE        | pg_attribute (parallel) | SHOW TABLE        | sqlite_master | SHOW CREATE        | Manual build     | JS comment block | Comment block  | DBMS_METADATA    | duckdb_tables() |
| **Dependent Types**       | No                 | Yes (ENUM)              | No                | No            | No                 | No               | No               | No             | No               | No              |
| **Dependent Seqs**        | No                 | Yes                     | No                | No            | No                 | No               | No               | No             | No               | No              |
| **C Bridge**              | CMariaDB           | CLibPQ                  | CLibPQ            | SDK SQLite3   | URLSession         | CFreeTDS         | CLibMongoc       | CRedis         | OracleNIO        | CDuckDB         |
| **Lines of Code**         | ~1440              | ~1478                   | ~652              | ~684          | ~868               | ~1105            | ~803+            | ~1412          | ~890             | ~908            |

---

## Known Gaps & Future Work

Based on `docs/development/plugin-extensibility-plan.md`:

### Current Limitations

- **~112 `switch databaseType` sites** across ~37 files — SQL dialect, DDL/DML generation, filter behavior, autocomplete, theme colors, icons, and connection form layout are still hardcoded in the host app
- **Schema DDL generation** (`SchemaStatementGenerator`) has NO plugin dispatch — entirely per-type branches in app
- **SQLDialectProvider** is app-side only — plugins cannot provide their own keywords/functions/types
- **MSSQL**: `applyQueryTimeout` uses `SET LOCK_TIMEOUT` (lock wait, not execution timeout)
- **Oracle**: `cancelQuery` uses default no-op (OracleNIO limitation)
- **MongoDB/Redis**: Fall back to `SQLiteDialect` in autocomplete (placeholder)

### Planned Phases (from extensibility plan)

1. **Phase 1**: Plugin capability descriptors (connection form, SQL dialect, icons)
2. **Phase 2**: SQL dialect as plugin-provided `SQLDialectDescriptor`
3. **Phase 3**: Schema DDL generation moved to plugin
4. **Phase 4**: Filter/query building fully delegated
5. **Phase 5**: Autocomplete provider as plugin capability
6. **Phase 6**: Theme/icon customization
7. **Phase 7**: Full third-party plugin marketplace

---

## File Reference

### TableProPluginKit

| File                                                       | Role                                                  |
| ---------------------------------------------------------- | ----------------------------------------------------- |
| `Plugins/TableProPluginKit/TableProPlugin.swift`           | Root plugin protocol                                  |
| `Plugins/TableProPluginKit/DriverPlugin.swift`             | Driver factory protocol                               |
| `Plugins/TableProPluginKit/PluginDatabaseDriver.swift`     | Core driver protocol (30+ methods)                    |
| `Plugins/TableProPluginKit/PluginCapability.swift`         | Capability enum                                       |
| `Plugins/TableProPluginKit/PluginQueryResult.swift`        | Query result transfer type                            |
| `Plugins/TableProPluginKit/PluginColumnInfo.swift`         | Column schema transfer type                           |
| `Plugins/TableProPluginKit/PluginTableInfo.swift`          | Table info transfer type                              |
| `Plugins/TableProPluginKit/PluginTableMetadata.swift`      | Table metadata transfer type                          |
| `Plugins/TableProPluginKit/PluginDatabaseMetadata.swift`   | Database metadata transfer type                       |
| `Plugins/TableProPluginKit/PluginForeignKeyInfo.swift`     | FK info transfer type                                 |
| `Plugins/TableProPluginKit/PluginIndexInfo.swift`          | Index info transfer type                              |
| `Plugins/TableProPluginKit/DriverConnectionConfig.swift`   | Connection config for plugins                         |
| `Plugins/TableProPluginKit/ConnectionField.swift`          | Custom connection field descriptor                    |
| `Plugins/TableProPluginKit/PluginConcurrencySupport.swift` | Async bridge for C calls                              |
| `Plugins/TableProPluginKit/PluginDriverError.swift`        | Error protocol                                        |
| `Plugins/TableProPluginKit/PluginSettingsStorage.swift`    | Namespaced UserDefaults                               |
| `Plugins/TableProPluginKit/SettablePlugin.swift`           | SettablePlugin + SettablePluginDiscoverable protocols |
| `Plugins/TableProPluginKit/PluginExportUtilities.swift`    | Export helpers                                        |
| `Plugins/TableProPluginKit/ExportFormatPlugin.swift`       | Export plugin protocol                                |
| `Plugins/TableProPluginKit/ImportFormatPlugin.swift`       | Import plugin protocol                                |
| `Plugins/TableProPluginKit/MongoShellParser.swift`         | MongoDB shell syntax parser                           |
| `Plugins/TableProPluginKit/PluginRowLimits.swift`          | Row limit constant                                    |
| `Plugins/TableProPluginKit/ConnectionMode.swift`           | Connection mode enum (network, fileBased)             |
| `Plugins/TableProPluginKit/EditorLanguage.swift`           | Editor language enum (sql, javascript, bash, custom)  |
| `Plugins/TableProPluginKit/GroupingStrategy.swift`         | Grouping strategy enum (byDatabase, bySchema, flat)   |
| `Plugins/TableProPluginKit/PluginExportTypes.swift`        | Export transfer types (table, option, error, sequence) |
| `Plugins/TableProPluginKit/PluginImportTypes.swift`        | Import transfer types (result, error, cancellation)   |
| `Plugins/TableProPluginKit/PluginExportProgress.swift`     | Export progress tracking                              |
| `Plugins/TableProPluginKit/PluginImportProgress.swift`     | Import progress tracking                              |
| `Plugins/TableProPluginKit/PluginExportDataSource.swift`   | Export data source protocol                           |
| `Plugins/TableProPluginKit/PluginImportDataSink.swift`     | Import data sink protocol                             |
| `Plugins/TableProPluginKit/PluginImportSource.swift`       | Import source protocol                                |

### Host App Core

| File                                                          | Role                                         |
| ------------------------------------------------------------- | -------------------------------------------- |
| `TablePro/Core/Plugins/PluginManager.swift`                   | Plugin discovery, loading, registration      |
| `TablePro/Core/Plugins/PluginDriverAdapter.swift`             | PluginDatabaseDriver → DatabaseDriver bridge |
| `TablePro/Core/Plugins/PluginModels.swift`                    | PluginEntry, PluginSource                    |
| `TablePro/Core/Plugins/PluginError.swift`                     | Plugin error cases                           |
| `TablePro/Core/Plugins/ExportDataSourceAdapter.swift`         | Export data source bridge                    |
| `TablePro/Core/Plugins/ImportDataSinkAdapter.swift`           | Import data sink bridge                      |
| `TablePro/Core/Plugins/SqlFileImportSource.swift`             | SQL file import streaming                    |
| `TablePro/Core/Plugins/Registry/PluginManager+Registry.swift` | Remote plugin download                       |
| `TablePro/Core/Database/DatabaseDriver.swift`                 | Internal driver protocol + factory           |
| `TablePro/Core/Database/DatabaseManager.swift`                | Session lifecycle, health monitoring         |
| `TablePro/Core/Database/ConnectionHealthMonitor.swift`        | 30s ping, reconnect backoff                  |
| `TablePro/Core/Services/Query/TableQueryBuilder.swift`        | Query construction with plugin dispatch      |
| `TablePro/Core/Services/Query/SQLDialectProvider.swift`       | Per-dialect keyword/type sets                |
| `TablePro/Core/Database/FilterSQLGenerator.swift`             | WHERE clause generation                      |
| `TablePro/Core/ChangeTracking/DataChangeManager.swift`        | Change tracking + plugin dispatch            |
| `TablePro/Core/ChangeTracking/SQLStatementGenerator.swift`    | INSERT/UPDATE/DELETE generation              |
| `TablePro/Core/ChangeTracking/DataChangeModels.swift`         | RowChange, CellChange types                  |
| `TablePro/Core/ChangeTracking/AnyChangeManager.swift`         | Type-erased change manager                   |
| `TablePro/Core/SchemaTracking/SchemaStatementGenerator.swift` | ALTER TABLE DDL generation                   |
| `TablePro/Models/Connection/DatabaseConnection.swift`         | DatabaseType enum + DatabaseConnection       |
| `TablePro/Models/Connection/ConnectionSession.swift`          | Runtime session state                        |
| `TablePro/Models/Schema/SchemaChange.swift`                   | Schema change operations                     |
| `TablePro/Models/Schema/ColumnDefinition.swift`               | Editable column definition                   |

### Plugin Bundles

| Plugin             | Main Driver File                                              |
| ------------------ | ------------------------------------------------------------- |
| MySQL              | `Plugins/MySQLDriverPlugin/MySQLPluginDriver.swift`           |
| MySQL (connection) | `Plugins/MySQLDriverPlugin/MariaDBPluginConnection.swift`     |
| PostgreSQL         | `Plugins/PostgreSQLDriverPlugin/PostgreSQLPluginDriver.swift` |
| Redshift           | `Plugins/PostgreSQLDriverPlugin/RedshiftPluginDriver.swift`   |
| SQLite             | `Plugins/SQLiteDriverPlugin/SQLitePlugin.swift`               |
| ClickHouse         | `Plugins/ClickHouseDriverPlugin/ClickHousePlugin.swift`       |
| MSSQL              | `Plugins/MSSQLDriverPlugin/MSSQLPlugin.swift`                 |
| MongoDB            | `Plugins/MongoDBDriverPlugin/MongoDBPluginDriver.swift`       |
| Redis              | `Plugins/RedisDriverPlugin/RedisPluginDriver.swift`           |
| Oracle             | `Plugins/OracleDriverPlugin/OraclePlugin.swift`               |
| DuckDB             | `Plugins/DuckDBDriverPlugin/DuckDBPlugin.swift`               |

### Documentation

| File                                            | Content                                     |
| ----------------------------------------------- | ------------------------------------------- |
| `docs/development/plugin-extensibility-plan.md` | 7-phase plan to eliminate ~112 switch sites |
| `docs/development/plugin-settings-tracking.md`  | Plugin settings progress tracking           |
| `docs/development/architecture.mdx`             | High-level architecture overview            |

---

## Documentation Accuracy Tracking

Last audited: 2026-03-11.

### Outstanding Inaccuracies

None — all tracked issues resolved.

### Resolved Inaccuracies

| Issue                                               | Resolution                                    | Date       |
| --------------------------------------------------- | --------------------------------------------- | ---------- |
| ExportFormatPlugin listed `optionsView()` (removed) | Replaced with SettablePlugin protocol section | 2026-03-11 |
| ImportFormatPlugin listed `optionsView()` (removed) | Replaced with SettablePlugin protocol section | 2026-03-11 |
| SettablePlugin.swift missing from File Reference    | Added to TableProPluginKit table              | 2026-03-11 |
| MSSQL listed cancelQuery/applyQueryTimeout as no-op | Updated: FreeTDS cancel + SET LOCK_TIMEOUT    | 2026-03-11 |
| MSSQL comparison matrix showed no-op                | Updated to FreeTDS cancel / SET LOCK_TIMEOUT  | 2026-03-11 |
| DriverPlugin missing 18 UI/capability properties    | Added all properties with types and defaults  | 2026-03-12 |
| Transfer Types missing 12 types                     | Added ConnectionMode, EditorLanguage, GroupingStrategy, export/import types | 2026-03-12 |
| ConnectionField missing FieldType/DropdownOption     | Updated with FieldType enum and DropdownOption | 2026-03-12 |
| ExportFormatPlugin missing 4 members                | Added defaultTableOptionValues, isTableExportable, currentFileExtension, warnings | 2026-03-12 |
| PluginManager missing 3 state properties            | Added pluginInstances, needsRestart, isInstalling | 2026-03-12 |
| DatabaseManager missing 2 state properties          | Added connectionListVersion, connectionStatusVersion | 2026-03-12 |
| MongoDB/Redis file count wrong (5 vs 6)             | Updated to 6 Swift + C bridge each           | 2026-03-12 |
| LOC counts off for Redis/PostgreSQL/MSSQL           | Updated: Redis ~1412, PostgreSQL ~1478, MSSQL ~1105 | 2026-03-12 |
