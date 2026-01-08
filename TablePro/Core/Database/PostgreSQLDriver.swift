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
            database: connection.database
        )

        do {
            try await pqConn.connect()
            self.libpqConnection = pqConn
            status = .connected
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
        guard let pqConn = libpqConnection else {
            throw DatabaseError.connectionFailed("Not connected to PostgreSQL")
        }

        let startTime = Date()

        do {
            let result = try await pqConn.executeQuery(query)

            return QueryResult(
                columns: result.columns,
                rows: result.rows,
                rowsAffected: result.affectedRows,
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )
        } catch {
            throw DatabaseError.queryFailed(error.localizedDescription)
        }
    }

    // MARK: - Schema

    func fetchTables() async throws -> [TableInfo] {
        let query = """
                SELECT table_name, table_type
                FROM information_schema.tables
                WHERE table_schema = 'public'
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
                    pgd.description
                FROM information_schema.columns c
                LEFT JOIN pg_catalog.pg_statio_all_tables st
                    ON st.schemaname = c.table_schema
                    AND st.relname = c.table_name
                LEFT JOIN pg_catalog.pg_description pgd
                    ON pgd.objoid = st.relid
                    AND pgd.objsubid = c.ordinal_position
                WHERE c.table_schema = 'public' AND c.table_name = '\(table)'
                ORDER BY c.ordinal_position
            """

        let result = try await execute(query: query)

        return result.rows.compactMap { row in
            guard row.count >= 4,
                  let name = row[0],
                  let dataType = row[1]
            else {
                return nil
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
                dataType: dataType.uppercased(),
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
            WHERE t.relname = '\(table)'
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
            WHERE tc.table_name = '\(table)'
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

    func fetchTableDDL(table: String) async throws -> String {
        // PostgreSQL doesn't have a direct equivalent to SHOW CREATE TABLE
        // We need to reconstruct it from system catalogs
        let query = """
            SELECT
                'CREATE TABLE ' || quote_ident(pg_namespace.nspname) || '.' || quote_ident(pg_class.relname) || ' (' ||
                E'\\n  ' ||
                string_agg(
                    quote_ident(pg_attribute.attname) || ' ' || format_type(pg_attribute.atttypid, pg_attribute.atttypmod) ||
                    CASE WHEN pg_attribute.attnotnull THEN ' NOT NULL' ELSE '' END ||
                    CASE WHEN pg_attribute.atthasdef THEN ' DEFAULT ' || pg_get_expr(pg_attrdef.adbin, pg_attrdef.adrelid) ELSE '' END,
                    E',\\n  '
                    ORDER BY pg_attribute.attnum
                ) ||
                E'\\n);' AS ddl
            FROM pg_attribute
            JOIN pg_class ON pg_class.oid = pg_attribute.attrelid
            JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
            LEFT JOIN pg_attrdef ON pg_attrdef.adrelid = pg_class.oid AND pg_attrdef.adnum = pg_attribute.attnum
            WHERE pg_class.relname = '\(table)'
              AND pg_namespace.nspname = 'public'
              AND pg_attribute.attnum > 0
              AND NOT pg_attribute.attisdropped
            GROUP BY pg_namespace.nspname, pg_class.relname
            """

        let result = try await execute(query: query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[0]
        else {
            throw DatabaseError.queryFailed("Failed to fetch DDL for table '\(table)'")
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
        // Escape single quotes to prevent SQL injection (string literal context)
        let safeTableName = tableName.replacingOccurrences(of: "'", with: "''")

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
            WHERE c.relname = '\(safeTableName)'
              AND n.nspname = 'public'
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

        let limitPattern = "(?i)\\s+LIMIT\\s+\\d+"
        if let regex = try? NSRegularExpression(pattern: limitPattern) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        let offsetPattern = "(?i)\\s+OFFSET\\s+\\d+"
        if let regex = try? NSRegularExpression(pattern: offsetPattern) {
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
}
