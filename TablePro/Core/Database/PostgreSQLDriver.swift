//
//  PostgreSQLDriver.swift
//  TablePro
//
//  PostgreSQL database driver using native libpq
//

import Foundation

/// PostgreSQL database driver using libpq native library
final class PostgreSQLDriver: DatabaseDriver {
    let connection: DatabaseConnection
    private(set) var status: ConnectionStatus = .disconnected

    /// Native libpq connection wrapper
    private var libpqConnection: LibPQConnection?

    /// Cached regex for stripping LIMIT clause
    private static let limitRegex = try? NSRegularExpression(pattern: "(?i)\\s+LIMIT\\s+\\d+")

    /// Cached regex for stripping OFFSET clause
    private static let offsetRegex = try? NSRegularExpression(pattern: "(?i)\\s+OFFSET\\s+\\d+")

    /// Current PostgreSQL schema (default: public)
    private(set) var currentSchema: String = "public"

    /// Escaped schema name for use in SQL string literals
    var escapedSchema: String {
        SQLEscaping.escapeStringLiteral(currentSchema, databaseType: .postgresql)
    }

    /// Server version string (e.g., "16.1.0")
    var serverVersion: String? {
        libpqConnection?.serverVersion()
    }

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    // MARK: - Connection

    func connect() async throws {
        status = .connecting

        // Create libpq connection with connection parameters
        let pqConn = LibPQConnection(
            host: connection.host,
            port: connection.port,
            user: connection.username,
            password: ConnectionStorage.shared.loadPassword(for: connection.id),
            database: connection.database,
            sslConfig: connection.sslConfig
        )

        do {
            try await pqConn.connect()
            self.libpqConnection = pqConn
            status = .connected

            // Detect current schema
            if let schemaResult = try? await pqConn.executeQuery("SELECT current_schema()"),
               let schema = schemaResult.rows.first?.first.flatMap({ $0 }) {
                currentSchema = schema
            }
        } catch {
            status = .error(error.localizedDescription)
            throw error
        }
    }

    func disconnect() {
        libpqConnection?.disconnect()
        libpqConnection = nil
        status = .disconnected
    }

    func testConnection() async throws -> Bool {
        try await connect()
        let isConnected = status == .connected
        disconnect()
        return isConnected
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        try await executeWithReconnect(query: query, isRetry: false)
    }

    /// Execute query with automatic reconnection on connection-lost errors
    private func executeWithReconnect(query: String, isRetry: Bool) async throws -> QueryResult {
        guard let pqConn = libpqConnection else {
            throw DatabaseError.connectionFailed("Not connected to PostgreSQL")
        }

        let startTime = Date()

        do {
            let result = try await pqConn.executeQuery(query)

            // Convert PostgreSQL Oids to ColumnType enum with raw type names
            let columnTypes = zip(result.columnOids, result.columnTypeNames).map { oid, rawType in
                ColumnType(fromPostgreSQLOid: oid, rawType: rawType)
            }

            return QueryResult(
                columns: result.columns,
                columnTypes: columnTypes,
                rows: result.rows,
                rowsAffected: result.affectedRows,
                executionTime: Date().timeIntervalSince(startTime),
                error: nil,
                isTruncated: result.isTruncated
            )
        } catch let error as NSError where !isRetry && isConnectionLostError(error) {
            // Connection lost - attempt reconnect and retry once
            try await reconnect()
            return try await executeWithReconnect(query: query, isRetry: true)
        } catch {
            throw DatabaseError.queryFailed(error.localizedDescription)
        }
    }

    // MARK: - Auto-Reconnect

    /// Check if error indicates a lost connection that can be recovered
    private func isConnectionLostError(_ error: NSError) -> Bool {
        // PostgreSQL connection error codes:
        // - "server closed the connection unexpectedly"
        // - "connection to server was lost"
        // - "no connection to the server"
        // - "could not send data to server"
        let errorMessage = error.localizedDescription.lowercased()
        return errorMessage.contains("connection") &&
            (errorMessage.contains("lost") ||
                errorMessage.contains("closed") ||
                errorMessage.contains("no connection") ||
                errorMessage.contains("could not send"))
    }

    /// Reconnect to the database
    private func reconnect() async throws {
        // Close existing connection
        libpqConnection?.disconnect()
        libpqConnection = nil
        status = .connecting

        // Reconnect using stored connection info
        try await connect()
    }

    // MARK: - Query Cancellation

    func cancelQuery() throws {
        libpqConnection?.cancelCurrentQuery()
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        try await executeParameterizedWithReconnect(query: query, parameters: parameters, isRetry: false)
    }

    /// Execute parameterized query with automatic reconnection
    private func executeParameterizedWithReconnect(query: String, parameters: [Any?], isRetry: Bool) async throws -> QueryResult {
        guard let pqConn = libpqConnection else {
            throw DatabaseError.connectionFailed("Not connected to PostgreSQL")
        }

        let startTime = Date()

        do {
            let result = try await pqConn.executeParameterizedQuery(query, parameters: parameters)

            // Convert PostgreSQL Oids to ColumnType enum with raw type names
            let columnTypes = zip(result.columnOids, result.columnTypeNames).map { oid, rawType in
                ColumnType(fromPostgreSQLOid: oid, rawType: rawType)
            }

            return QueryResult(
                columns: result.columns,
                columnTypes: columnTypes,
                rows: result.rows,
                rowsAffected: result.affectedRows,
                executionTime: Date().timeIntervalSince(startTime),
                error: nil,
                isTruncated: result.isTruncated
            )
        } catch let error as NSError where !isRetry && isConnectionLostError(error) {
            // Connection lost - attempt reconnect and retry once
            try await reconnect()
            return try await executeParameterizedWithReconnect(query: query, parameters: parameters, isRetry: true)
        } catch {
            throw DatabaseError.queryFailed(error.localizedDescription)
        }
    }

    // MARK: - Schema

    func fetchTables() async throws -> [TableInfo] {
        let query = """
                SELECT table_name, table_type
                FROM information_schema.tables
                WHERE table_schema = '\(escapedSchema)'
                ORDER BY table_name
            """

        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard let name = row[0] else { return nil }
            let typeStr = row[1] ?? "BASE TABLE"
            let type: TableInfo.TableType = typeStr.contains("VIEW") ? .view : .table

            return TableInfo(name: name, type: type, rowCount: nil)
        }
    }

    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        let query = """
                SELECT
                    c.column_name,
                    c.data_type,
                    c.is_nullable,
                    c.column_default,
                    c.collation_name,
                    pgd.description,
                    c.udt_name
                FROM information_schema.columns c
                LEFT JOIN pg_catalog.pg_statio_all_tables st
                    ON st.schemaname = c.table_schema
                    AND st.relname = c.table_name
                LEFT JOIN pg_catalog.pg_description pgd
                    ON pgd.objoid = st.relid
                    AND pgd.objsubid = c.ordinal_position
                WHERE c.table_schema = '\(escapedSchema)' AND c.table_name = '\(SQLEscaping.escapeStringLiteral(table, databaseType: .postgresql))'
                ORDER BY c.ordinal_position
            """

        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard row.count >= 4,
                  let name = row[0],
                  let rawDataType = row[1]
            else {
                return nil
            }

            let udtName = row.count > 6 ? row[6] : nil

            // Format user-defined enum types for downstream parsing
            let dataType: String
            if rawDataType.uppercased() == "USER-DEFINED", let udt = udtName {
                dataType = "ENUM(\(udt))"
            } else {
                dataType = rawDataType.uppercased()
            }

            let isNullable = row[2] == "YES"
            let defaultValue = row[3]
            let collation = row.count > 4 ? row[4] : nil
            let comment = row.count > 5 ? row[5] : nil

            // PostgreSQL doesn't have separate charset - it uses database encoding
            // Collation format: "en_US.UTF-8" or "C" or "POSIX"
            let charset: String? = {
                guard let coll = collation else { return nil }
                if coll.contains(".") {
                    // Extract encoding from "locale.ENCODING" format
                    return coll.components(separatedBy: ".").last
                }
                return nil
            }()

            return ColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: false,
                defaultValue: defaultValue,
                extra: nil,
                charset: charset,
                collation: collation,
                comment: comment?.isEmpty == false ? comment : nil
            )
        }
    }

    /// Bulk-fetch columns for all tables using a single information_schema query
    /// (avoids N+1 per-table queries).
    /// Scoped to the active schema, matching `fetchTables()` and `fetchColumns()`.
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] {
        let query = """
            SELECT
                c.table_name,
                c.column_name,
                c.data_type,
                c.is_nullable,
                c.column_default,
                c.collation_name,
                pgd.description,
                c.udt_name
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_statio_all_tables st
                ON st.schemaname = c.table_schema
                AND st.relname = c.table_name
            LEFT JOIN pg_catalog.pg_description pgd
                ON pgd.objoid = st.relid
                AND pgd.objsubid = c.ordinal_position
            WHERE c.table_schema = '\(escapedSchema)'
            ORDER BY c.table_name, c.ordinal_position
            """

        let result = try await execute(query: query)

        var allColumns: [String: [ColumnInfo]] = [:]
        for row in result.rows {
            guard row.count >= 5,
                  let tableName = row[0],
                  let name = row[1],
                  let rawDataType = row[2]
            else {
                continue
            }

            let udtName = row.count > 7 ? row[7] : nil

            let dataType: String
            if rawDataType.uppercased() == "USER-DEFINED", let udt = udtName {
                dataType = "ENUM(\(udt))"
            } else {
                dataType = rawDataType.uppercased()
            }

            let isNullable = row[3] == "YES"
            let defaultValue = row[4]
            let collation = row.count > 5 ? row[5] : nil
            let comment = row.count > 6 ? row[6] : nil

            let charset: String? = {
                guard let coll = collation else { return nil }
                if coll.contains(".") {
                    return coll.components(separatedBy: ".").last
                }
                return nil
            }()

            let column = ColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: false,
                defaultValue: defaultValue,
                extra: nil,
                charset: charset,
                collation: collation,
                comment: comment?.isEmpty == false ? comment : nil
            )

            allColumns[tableName, default: []].append(column)
        }

        return allColumns
    }

    /// Fetch allowed values for a PostgreSQL user-defined enum type
    func fetchEnumValues(typeName: String) async throws -> [String] {
        let query = """
            SELECT e.enumlabel
            FROM pg_enum e
            JOIN pg_type t ON e.enumtypid = t.oid
            WHERE t.typname = '\(SQLEscaping.escapeStringLiteral(typeName, databaseType: .postgresql))'
            ORDER BY e.enumsortorder
        """
        let result = try await execute(query: query)
        return result.rows.compactMap { $0.first ?? nil }
    }

    /// Fetch enum type definitions used by columns in the given table.
    /// Returns array of (typeName, enumLabels) tuples.
    func fetchEnumTypesForTable(_ table: String) async throws -> [(name: String, labels: [String])] {
        let safeTable = SQLEscaping.escapeStringLiteral(table, databaseType: .postgresql)
        let query = """
            SELECT DISTINCT t.typname,
                   array_agg(e.enumlabel ORDER BY e.enumsortorder)
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_type t ON t.oid = a.atttypid
            JOIN pg_enum e ON e.enumtypid = t.oid
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(escapedSchema)'
              AND a.attnum > 0
              AND NOT a.attisdropped
            GROUP BY t.typname
            ORDER BY t.typname
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let typeName = row[0], let labelsStr = row[1] else { return nil }
            let labels = labelsStr
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .components(separatedBy: ",")
            return (name: typeName, labels: labels)
        }
    }

    /// Protocol conformance: fetch dependent type definitions for a table.
    func fetchDependentTypes(forTable table: String) async throws -> [(name: String, labels: [String])] {
        try await fetchEnumTypesForTable(table)
    }


    /// Fetch sequences referenced in column defaults (nextval) for the given table.
    /// Returns array of (sequenceName, CREATE SEQUENCE DDL) pairs.
    func fetchDependentSequences(forTable table: String) async throws -> [(name: String, ddl: String)] {
        let safeTable = SQLEscaping.escapeStringLiteral(table, databaseType: .postgresql)
        let query = """
            SELECT s.sequencename,
                   s.start_value,
                   s.min_value,
                   s.max_value,
                   s.increment_by,
                   s.cycle
            FROM pg_attrdef ad
            JOIN pg_class c ON c.oid = ad.adrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_sequences s ON s.schemaname = n.nspname
                 AND pg_get_expr(ad.adbin, ad.adrelid) LIKE '%' || quote_ident(s.sequencename) || '%'
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(escapedSchema)'
              AND pg_get_expr(ad.adbin, ad.adrelid) LIKE '%nextval%'
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let seqName = row[0] else { return nil }
            let startVal = row[1] ?? "1"
            let minVal = row[2] ?? "1"
            let maxVal = row[3] ?? "9223372036854775807"
            let incrementBy = row[4] ?? "1"
            let cycle = row[5] == "t" ? " CYCLE" : ""
            let ddl = "CREATE SEQUENCE \"\(seqName)\" INCREMENT BY \(incrementBy)"
                + " MINVALUE \(minVal) MAXVALUE \(maxVal)"
                + " START WITH \(startVal)\(cycle);"
            return (name: seqName, ddl: ddl)
        }
    }

    func fetchIndexes(table: String) async throws -> [IndexInfo] {
        let query = """
            SELECT
                i.relname AS index_name,
                ARRAY_AGG(a.attname ORDER BY array_position(ix.indkey, a.attnum)) AS columns,
                ix.indisunique AS is_unique,
                ix.indisprimary AS is_primary,
                am.amname AS index_type
            FROM pg_index ix
            JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_class t ON t.oid = ix.indrelid
            JOIN pg_am am ON am.oid = i.relam
            JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
            WHERE t.relname = '\(SQLEscaping.escapeStringLiteral(table, databaseType: .postgresql))'
            GROUP BY i.relname, ix.indisunique, ix.indisprimary, am.amname
            ORDER BY ix.indisprimary DESC, i.relname
            """

        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard row.count >= 5,
                  let name = row[0],
                  let columnsStr = row[1]
            else {
                return nil
            }

            // Parse PostgreSQL array format: {col1,col2}
            let columns =
                columnsStr
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .components(separatedBy: ",")

            return IndexInfo(
                name: name,
                columns: columns,
                isUnique: row[2] == "t",
                isPrimary: row[3] == "t",
                type: row[4]?.uppercased() ?? "BTREE"
            )
        }
    }

    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] {
        let query = """
            SELECT
                tc.constraint_name,
                kcu.column_name,
                ccu.table_name AS referenced_table,
                ccu.column_name AS referenced_column,
                rc.delete_rule,
                rc.update_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
            JOIN information_schema.referential_constraints rc
                ON tc.constraint_name = rc.constraint_name
            JOIN information_schema.constraint_column_usage ccu
                ON rc.unique_constraint_name = ccu.constraint_name
            WHERE tc.table_name = '\(SQLEscaping.escapeStringLiteral(table, databaseType: .postgresql))'
                AND tc.constraint_type = 'FOREIGN KEY'
            ORDER BY tc.constraint_name
            """

        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard row.count >= 6,
                  let name = row[0],
                  let column = row[1],
                  let refTable = row[2],
                  let refColumn = row[3]
            else {
                return nil
            }

            return ForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                onDelete: row[4] ?? "NO ACTION",
                onUpdate: row[5] ?? "NO ACTION"
            )
        }
    }

    func fetchApproximateRowCount(table: String) async throws -> Int? {
        let query = """
            SELECT reltuples::bigint
            FROM pg_class
            WHERE relname = '\(SQLEscaping.escapeStringLiteral(table, databaseType: .postgresql))'
              AND relnamespace = (
                  SELECT oid FROM pg_namespace WHERE nspname = current_schema()
              )
            """

        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let value = firstRow[0],
              let count = Int(value)
        else {
            return nil
        }

        // pg_class.reltuples can be -1 if never analyzed
        return count >= 0 ? count : nil
    }

    func fetchTableDDL(table: String) async throws -> String {
        // PostgreSQL doesn't have a direct equivalent to SHOW CREATE TABLE
        // We need to reconstruct it from system catalogs in multiple queries
        let safeTable = SQLEscaping.escapeStringLiteral(table, databaseType: .postgresql)
        let quotedTable = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""

        // 1. Get column definitions
        let columnsQuery = """
            SELECT
                quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod) ||
                CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END ||
                CASE WHEN a.atthasdef THEN ' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid) ELSE '' END
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(escapedSchema)'
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY a.attnum
            """

        // 2. Get table constraints (PRIMARY KEY, UNIQUE, CHECK, FOREIGN KEY)
        let constraintsQuery = """
            SELECT
                pg_get_constraintdef(con.oid, true)
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(escapedSchema)'
              AND con.contype IN ('p', 'u', 'c', 'f')
            ORDER BY
              CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'c' THEN 2 WHEN 'f' THEN 3 END
            """

        // 3. Get indexes (excluding those backing constraints)
        let indexesQuery = """
            SELECT indexdef
            FROM pg_indexes
            WHERE tablename = '\(safeTable)'
              AND schemaname = '\(escapedSchema)'
              AND indexname NOT IN (
                SELECT conname FROM pg_constraint
                JOIN pg_class ON pg_class.oid = conrelid
                JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
                WHERE pg_class.relname = '\(safeTable)'
                  AND pg_namespace.nspname = '\(escapedSchema)'
              )
            ORDER BY indexname
            """

        // Dispatch all three queries independently via async let for cleaner control flow;
        // they execute sequentially on LibPQConnection's serial queue
        async let columnsResult = execute(query: columnsQuery)
        async let constraintsResult = execute(query: constraintsQuery)
        async let indexesResult = execute(query: indexesQuery)

        let (cols, cons, idxs) = try await (columnsResult, constraintsResult, indexesResult)

        // Process results
        let columnDefs = cols.rows.compactMap { $0[0] }

        guard !columnDefs.isEmpty else {
            throw DatabaseError.queryFailed("Failed to fetch DDL for table '\(table)'")
        }

        let constraints = cons.rows.compactMap { $0[0] }

        // 4. Build CREATE TABLE statement
        var parts = columnDefs
        parts.append(contentsOf: constraints)

        let quotedSchema = "\"\(currentSchema.replacingOccurrences(of: "\"", with: "\"\""))\""
        let ddl = "CREATE TABLE \(quotedSchema).\(quotedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        let indexDefs = idxs.rows.compactMap { $0[0] }

        if indexDefs.isEmpty {
            return ddl
        }

        return ddl + "\n\n" + indexDefs.joined(separator: ";\n") + ";"
    }

    func fetchViewDefinition(view: String) async throws -> String {
        let query = """
            SELECT 'CREATE OR REPLACE VIEW ' || quote_ident(schemaname) || '.' || quote_ident(viewname) || ' AS ' || E'\\n' || definition AS ddl
            FROM pg_views
            WHERE viewname = '\(SQLEscaping.escapeStringLiteral(view, databaseType: .postgresql))'
              AND schemaname = '\(escapedSchema)'
            """

        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[0]
        else {
            throw DatabaseError.queryFailed("Failed to fetch definition for view '\(view)'")
        }

        return ddl
    }

    // MARK: - Paginated Query Support

    func fetchRowCount(query: String) async throws -> Int {
        let baseQuery = stripLimitOffset(from: query)
        let countQuery = "SELECT COUNT(*) FROM (\(baseQuery)) AS __count_subquery__"

        let result = try await execute(query: countQuery)
        guard let firstRow = result.rows.first, let countStr = firstRow.first else { return 0 }
        return Int(countStr ?? "0") ?? 0
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult {
        let baseQuery = stripLimitOffset(from: query)
        let paginatedQuery = "\(baseQuery) LIMIT \(limit) OFFSET \(offset)"
        return try await execute(query: paginatedQuery)
    }

    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        let query = """
            SELECT
                pg_total_relation_size(c.oid) AS total_size,
                pg_table_size(c.oid) AS data_size,
                pg_indexes_size(c.oid) AS index_size,
                c.reltuples::bigint AS row_count,
                CASE WHEN c.reltuples > 0 THEN pg_table_size(c.oid) / GREATEST(c.reltuples, 1) ELSE 0 END AS avg_row_length,
                obj_description(c.oid, 'pg_class') AS comment
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '\(SQLEscaping.escapeStringLiteral(tableName, databaseType: .postgresql))'
              AND n.nspname = '\(escapedSchema)'
            """

        let result = try await execute(query: query)

        guard let row = result.rows.first else {
            return TableMetadata(
                tableName: tableName,
                dataSize: nil,
                indexSize: nil,
                totalSize: nil,
                avgRowLength: nil,
                rowCount: nil,
                comment: nil,
                engine: nil,
                collation: nil,
                createTime: nil,
                updateTime: nil
            )
        }

        let totalSize = !row.isEmpty ? Int64(row[0] ?? "0") : nil
        let dataSize = row.count > 1 ? Int64(row[1] ?? "0") : nil
        let indexSize = row.count > 2 ? Int64(row[2] ?? "0") : nil
        let rowCount = row.count > 3 ? Int64(row[3] ?? "0") : nil
        let avgRowLength = row.count > 4 ? Int64(row[4] ?? "0") : nil
        let comment = row.count > 5 ? row[5] : nil

        return TableMetadata(
            tableName: tableName,
            dataSize: dataSize,
            indexSize: indexSize,
            totalSize: totalSize,
            avgRowLength: avgRowLength,
            rowCount: rowCount,
            comment: comment?.isEmpty == true ? nil : comment,
            engine: "PostgreSQL",
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }

    private func stripLimitOffset(from query: String) -> String {
        var result = query

        if let regex = Self.limitRegex {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        if let regex = Self.offsetRegex {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetch list of all databases on the server
    func fetchDatabases() async throws -> [String] {
        let result = try await execute(query: "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname")
        return result.rows.compactMap { row in row.first.flatMap { $0 } }
    }

    /// Fetch list of schemas (excludes system schemas)
    func fetchSchemas() async throws -> [String] {
        let result = try await execute(query: """
            SELECT schema_name FROM information_schema.schemata
            WHERE schema_name NOT LIKE 'pg_%'
              AND schema_name <> 'information_schema'
            ORDER BY schema_name
            """)
        return result.rows.compactMap { row in row.first.flatMap { $0 } }
    }

    /// Switch to a different schema by setting search_path
    func switchSchema(to schema: String) async throws {
        let escapedName = schema.replacingOccurrences(of: "\"", with: "\"\"")
        _ = try await execute(query: "SET search_path TO \"\(escapedName)\", public")
        currentSchema = schema
    }

    /// Fetch metadata for a specific database
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        // Escape database name for use as a SQL string literal
        let escapedDbLiteral = SQLEscaping.escapeStringLiteral(database, databaseType: .postgresql)

        // Single query for both table count and database size
        let query = """
            SELECT
                (SELECT COUNT(*)
                 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_catalog = '\(escapedDbLiteral)'),
                pg_database_size('\(escapedDbLiteral)')
        """
        let result = try await execute(query: query)
        let row = result.rows.first
        let tableCount = Int(row?[0] ?? "0") ?? 0
        let sizeBytes = Int64(row?[1] ?? "0") ?? 0

        // Determine if system database
        let systemDatabases = ["postgres", "template0", "template1"]
        let isSystem = systemDatabases.contains(database)

        return DatabaseMetadata(
            id: database,
            name: database,
            tableCount: tableCount,
            sizeBytes: sizeBytes,
            lastAccessed: nil,
            isSystemDatabase: isSystem,
            icon: isSystem ? "gearshape.fill" : "cylinder.fill"
        )
    }

    /// Create a new database
    func createDatabase(name: String, charset: String, collation: String?) async throws {
        // Escape double quotes in database name (PostgreSQL identifiers)
        let escapedName = name.replacingOccurrences(of: "\"", with: "\"\"")

        // Validate charset (basic validation)
        let validCharsets = ["UTF8", "LATIN1", "SQL_ASCII"]
        let normalizedCharset = charset.uppercased()
        guard validCharsets.contains(normalizedCharset) else {
            throw DatabaseError.queryFailed("Invalid encoding: \(charset)")
        }

        var query = "CREATE DATABASE \"\(escapedName)\" ENCODING '\(normalizedCharset)'"

        // Validate and add collation if provided
        if let collation = collation {
            // Strict validation: allow only typical locale/collation characters
            let allowedCollationChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
            let isValidCollation = collation.unicodeScalars.allSatisfy { allowedCollationChars.contains($0) }
            guard isValidCollation else {
                throw DatabaseError.queryFailed("Invalid collation")
            }
            // Escape single quotes for safe SQL literal usage
            let escapedCollation = collation.replacingOccurrences(of: "'", with: "''")
            query += " LC_COLLATE '\(escapedCollation)'"
        }

        _ = try await execute(query: query)
    }
}
