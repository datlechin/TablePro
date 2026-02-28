//
//  MongoDBDriver.swift
//  TablePro
//
//  MongoDB database driver using libmongoc via MongoDBConnection.
//  Translates MongoDB Shell syntax into MongoDBConnection API calls.
//

import Foundation
import OSLog

/// MongoDB database driver implementing the DatabaseDriver protocol.
/// Parses mongo shell syntax (db.collection.find/insert/update/delete)
/// and dispatches to MongoDBConnection for execution.
final class MongoDBDriver: DatabaseDriver {
    let connection: DatabaseConnection
    private(set) var status: ConnectionStatus = .disconnected

    private var mongoConnection: MongoDBConnection?

    private static let logger = Logger(subsystem: "com.TablePro", category: "MongoDBDriver")

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    // MARK: - Server Version

    var serverVersion: String? {
        mongoConnection?.serverVersion()
    }

    // MARK: - Connection Management

    func connect() async throws {
        status = .connecting

        let password = ConnectionStorage.shared.loadPassword(for: connection.id)

        let conn = MongoDBConnection(
            host: connection.host,
            port: connection.port,
            user: connection.username,
            password: password,
            database: connection.database,
            sslConfig: connection.sslConfig
        )

        do {
            try await conn.connect()
            mongoConnection = conn
            status = .connected
        } catch {
            status = .error(error.localizedDescription)
            throw DatabaseError.connectionFailed(error.localizedDescription)
        }
    }

    func disconnect() {
        mongoConnection?.disconnect()
        mongoConnection = nil
        status = .disconnected
    }

    func testConnection() async throws -> Bool {
        try await connect()
        let isConnected = status == .connected
        disconnect()
        return isConnected
    }

    // MARK: - Configuration

    func applyQueryTimeout(_ seconds: Int) async throws {
        // MongoDB timeouts are handled per-operation at the connection level
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        let startTime = Date()

        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Health monitor sends "SELECT 1" as a ping -- intercept and remap
        if trimmed.lowercased() == "select 1" {
            _ = try await conn.ping()
            return QueryResult(
                columns: ["ok"],
                columnTypes: [.integer(rawType: "Int32")],
                rows: [["1"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )
        }

        let operation: MongoOperation
        do {
            operation = try MongoShellParser.parse(trimmed)
        } catch {
            throw DatabaseError.queryFailed(error.localizedDescription)
        }

        return try await executeOperation(operation, connection: conn, startTime: startTime)
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        // MongoDB shell syntax is self-contained; parameters are embedded in the query
        try await execute(query: query)
    }

    // MARK: - Query Cancellation

    func cancelQuery() throws {
        mongoConnection?.cancelCurrentQuery()
    }

    // MARK: - Paginated Query Support

    func fetchRowCount(query: String) async throws -> Int {
        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let db = connection.database

        do {
            let operation = try MongoShellParser.parse(trimmed)

            switch operation {
            case .find(let collection, let filter, _):
                let count = try await conn.countDocuments(database: db, collection: collection, filter: filter)
                return Int(count)

            case .findOne:
                return 1

            case .aggregate(let collection, let pipeline):
                // For aggregation, we must run it and count results
                let docs = try await conn.aggregate(database: db, collection: collection, pipeline: pipeline)
                return docs.count

            case .countDocuments(let collection, let filter):
                let count = try await conn.countDocuments(database: db, collection: collection, filter: filter)
                return Int(count)

            default:
                return 0
            }
        } catch {
            throw DatabaseError.queryFailed(error.localizedDescription)
        }
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult {
        let startTime = Date()

        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let db = connection.database

        do {
            let operation = try MongoShellParser.parse(trimmed)

            switch operation {
            case .find(let collection, let filter, var options):
                // Override skip/limit for pagination
                options.skip = offset
                options.limit = limit
                let docs = try await conn.find(
                    database: db,
                    collection: collection,
                    filter: filter,
                    sort: options.sort,
                    projection: options.projection,
                    skip: offset,
                    limit: limit
                )
                return buildQueryResult(from: docs, startTime: startTime)

            default:
                // For non-find operations, execute as-is
                return try await executeOperation(operation, connection: conn, startTime: startTime)
            }
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError.queryFailed(error.localizedDescription)
        }
    }

    // MARK: - Schema Operations

    func fetchTables() async throws -> [TableInfo] {
        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        let collections = try await conn.listCollections(database: connection.database)
        return collections.map { TableInfo(name: $0, type: .table, rowCount: nil) }
    }

    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        let db = connection.database

        // Sample first 100 documents to discover schema
        let docs = try await conn.find(
            database: db,
            collection: table,
            filter: "{}",
            sort: nil,
            projection: nil,
            skip: 0,
            limit: 100
        )

        if docs.isEmpty {
            // Empty collection -- return _id only
            return [
                ColumnInfo(
                    name: "_id",
                    dataType: "ObjectId",
                    isNullable: false,
                    isPrimaryKey: true,
                    defaultValue: nil,
                    extra: nil,
                    charset: nil,
                    collation: nil,
                    comment: nil
                )
            ]
        }

        let columns = BsonDocumentFlattener.unionColumns(from: docs)
        let types = BsonDocumentFlattener.columnTypes(for: columns, documents: docs)

        return columns.enumerated().map { index, name in
            let columnType = ColumnType(fromBsonType: types[index])
            return ColumnInfo(
                name: name,
                dataType: columnType.displayName,
                isNullable: name != "_id",
                isPrimaryKey: name == "_id",
                defaultValue: nil,
                extra: nil,
                charset: nil,
                collation: nil,
                comment: nil
            )
        }
    }

    func fetchIndexes(table: String) async throws -> [IndexInfo] {
        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        let indexes = try await conn.listIndexes(database: connection.database, collection: table)

        return indexes.compactMap { indexDoc -> IndexInfo? in
            guard let name = indexDoc["name"] as? String,
                  let key = indexDoc["key"] as? [String: Any]
            else {
                return nil
            }

            let columns = Array(key.keys)
            let isUnique = (indexDoc["unique"] as? Bool) ?? (name == "_id_")
            let isPrimary = name == "_id_"

            return IndexInfo(
                name: name,
                columns: columns,
                isUnique: isUnique,
                isPrimary: isPrimary,
                type: "BTREE"
            )
        }
    }

    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] {
        // MongoDB does not have foreign keys
        []
    }

    func fetchApproximateRowCount(table: String) async throws -> Int? {
        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        let count = try await conn.countDocuments(database: connection.database, collection: table, filter: "{}")
        return Int(count)
    }

    func fetchTableDDL(table: String) async throws -> String {
        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        let db = connection.database

        // Fetch collection info with validator (schema validation)
        do {
            let result = try await conn.runCommand(
                "{\"listCollections\": 1, \"filter\": {\"name\": \"\(escapeJsonString(table))\"}}",
                database: db
            )

            if let firstDoc = result.first,
               let cursor = firstDoc["cursor"] as? [String: Any],
               let firstBatch = cursor["firstBatch"] as? [[String: Any]],
               let collInfo = firstBatch.first,
               let options = collInfo["options"] as? [String: Any],
               let validator = options["validator"] {
                let json = BsonDocumentFlattener.serializeToJson(validator)
                return "// Collection: \(table)\n// Validator:\n\(json)"
            }
        } catch {
            Self.logger.debug("Failed to fetch validator for \(table): \(error.localizedDescription)")
        }

        return "// Collection: \(table)\n// No schema validator defined."
    }

    func fetchViewDefinition(view: String) async throws -> String {
        throw DatabaseError.unsupportedOperation
    }

    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        let db = connection.database

        do {
            let result = try await conn.runCommand(
                "{\"collStats\": \"\(escapeJsonString(tableName))\"}",
                database: db
            )

            if let stats = result.first {
                let count = (stats["count"] as? Int64)
                    ?? (stats["count"] as? Int).map(Int64.init)
                let totalIndexSize = (stats["totalIndexSize"] as? Int64)
                    ?? (stats["totalIndexSize"] as? Int).map(Int64.init)
                let storageSize = (stats["storageSize"] as? Int64)
                    ?? (stats["storageSize"] as? Int).map(Int64.init)
                let avgObjSize = (stats["avgObjSize"] as? Int64)
                    ?? (stats["avgObjSize"] as? Int).map(Int64.init)

                let totalSize: Int64? = {
                    guard let s = storageSize, let idx = totalIndexSize else { return nil }
                    return s + idx
                }()

                return TableMetadata(
                    tableName: tableName,
                    dataSize: storageSize,
                    indexSize: totalIndexSize,
                    totalSize: totalSize,
                    avgRowLength: avgObjSize,
                    rowCount: count,
                    comment: nil,
                    engine: "MongoDB",
                    collation: nil,
                    createTime: nil,
                    updateTime: nil
                )
            }
        } catch {
            Self.logger.debug("collStats failed for \(tableName): \(error.localizedDescription)")
        }

        return TableMetadata(
            tableName: tableName,
            dataSize: nil,
            indexSize: nil,
            totalSize: nil,
            avgRowLength: nil,
            rowCount: nil,
            comment: nil,
            engine: "MongoDB",
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }

    func fetchDatabases() async throws -> [String] {
        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        return try await conn.listDatabases()
    }

    func fetchSchemas() async throws -> [String] {
        // MongoDB does not have schemas
        []
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        let systemDatabases = ["admin", "config", "local"]
        let isSystem = systemDatabases.contains(database)

        do {
            let result = try await conn.runCommand("{\"dbStats\": 1}", database: database)

            if let stats = result.first {
                let collections = (stats["collections"] as? Int)
                    ?? (stats["collections"] as? Int64).map(Int.init)
                let dataSize = (stats["dataSize"] as? Int64)
                    ?? (stats["dataSize"] as? Int).map(Int64.init)

                return DatabaseMetadata(
                    id: database,
                    name: database,
                    tableCount: collections,
                    sizeBytes: dataSize,
                    lastAccessed: nil,
                    isSystemDatabase: isSystem,
                    icon: isSystem ? "gearshape.fill" : "cylinder.fill"
                )
            }
        } catch {
            Self.logger.debug("dbStats failed for \(database): \(error.localizedDescription)")
        }

        return DatabaseMetadata.minimal(name: database, isSystem: isSystem)
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        guard let conn = mongoConnection else {
            throw DatabaseError.notConnected
        }

        // MongoDB creates databases implicitly on first write.
        // Insert a temp document into a temp collection to materialize the database.
        _ = try await conn.insertOne(
            database: name,
            collection: "__tablepro_init",
            document: "{\"_init\": true}"
        )

        // Drop the temp collection so we don't leave garbage
        _ = try await conn.runCommand(
            "{\"drop\": \"__tablepro_init\"}",
            database: name
        )
    }

    // MARK: - Transaction Management

    func beginTransaction() async throws {
        throw DatabaseError.unsupportedOperation
    }

    func commitTransaction() async throws {
        throw DatabaseError.unsupportedOperation
    }

    func rollbackTransaction() async throws {
        throw DatabaseError.unsupportedOperation
    }
}

// MARK: - Operation Dispatch

private extension MongoDBDriver {
    func executeOperation(
        _ operation: MongoOperation,
        connection conn: MongoDBConnection,
        startTime: Date
    ) async throws -> QueryResult {
        let db = self.connection.database

        switch operation {
        case .find(let collection, let filter, let options):
            let docs = try await conn.find(
                database: db,
                collection: collection,
                filter: filter,
                sort: options.sort,
                projection: options.projection,
                skip: options.skip ?? 0,
                limit: options.limit ?? DriverRowLimits.defaultMax
            )
            return buildQueryResult(from: docs, startTime: startTime)

        case .findOne(let collection, let filter):
            let docs = try await conn.find(
                database: db,
                collection: collection,
                filter: filter,
                sort: nil,
                projection: nil,
                skip: 0,
                limit: 1
            )
            return buildQueryResult(from: docs, startTime: startTime)

        case .aggregate(let collection, let pipeline):
            let docs = try await conn.aggregate(database: db, collection: collection, pipeline: pipeline)
            return buildQueryResult(from: docs, startTime: startTime)

        case .countDocuments(let collection, let filter):
            let count = try await conn.countDocuments(database: db, collection: collection, filter: filter)
            return QueryResult(
                columns: ["count"],
                columnTypes: [.integer(rawType: "Int64")],
                rows: [[String(count)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )

        case .insertOne, .insertMany, .updateOne, .updateMany, .replaceOne,
             .deleteOne, .deleteMany, .createIndex, .dropIndex, .drop:
            return try await executeWriteOperation(operation, connection: conn, database: db, startTime: startTime)

        case .runCommand(let command):
            let result = try await conn.runCommand(command, database: db)
            return buildQueryResult(from: result, startTime: startTime)

        case .listCollections:
            let collections = try await conn.listCollections(database: db)
            return QueryResult(
                columns: ["collection"],
                columnTypes: [.text(rawType: "String")],
                rows: collections.map { [$0] },
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )

        case .listDatabases:
            let databases = try await conn.listDatabases()
            return QueryResult(
                columns: ["database"],
                columnTypes: [.text(rawType: "String")],
                rows: databases.map { [$0] },
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )

        case .ping:
            _ = try await conn.ping()
            return QueryResult(
                columns: ["ok"],
                columnTypes: [.integer(rawType: "Int32")],
                rows: [["1"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )
        }
    }

    func executeWriteOperation(
        _ operation: MongoOperation,
        connection conn: MongoDBConnection,
        database db: String,
        startTime: Date
    ) async throws -> QueryResult {
        switch operation {
        case .insertOne(let collection, let document):
            let insertedId = try await conn.insertOne(database: db, collection: collection, document: document)
            let idStr = insertedId ?? "null"
            return QueryResult(
                columns: ["insertedId"],
                columnTypes: [.text(rawType: "ObjectId")],
                rows: [[idStr]],
                rowsAffected: 1,
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )

        case .insertMany(let collection, let documents):
            let cmd = "{\"insert\": \"\(escapeJsonString(collection))\", \"documents\": \(documents)}"
            let result = try await conn.runCommand(cmd, database: db)
            let inserted = (result.first?["n"] as? Int) ?? 0
            return QueryResult(
                columns: ["insertedCount"],
                columnTypes: [.integer(rawType: "Int32")],
                rows: [[String(inserted)]],
                rowsAffected: inserted,
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )

        case .updateOne(let collection, let filter, let update):
            let modified = try await conn.updateOne(database: db, collection: collection, filter: filter, update: update)
            return QueryResult(
                columns: ["modifiedCount"],
                columnTypes: [.integer(rawType: "Int64")],
                rows: [[String(modified)]],
                rowsAffected: Int(modified),
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )

        case .updateMany(let collection, let filter, let update):
            let cmd = """
                {"update": "\(escapeJsonString(collection))", \
                "updates": [{"q": \(filter), "u": \(update), "multi": true}]}
                """
            let result = try await conn.runCommand(cmd, database: db)
            let modified = (result.first?["nModified"] as? Int64)
                ?? (result.first?["nModified"] as? Int).map(Int64.init)
                ?? 0
            return QueryResult(
                columns: ["modifiedCount"],
                columnTypes: [.integer(rawType: "Int64")],
                rows: [[String(modified)]],
                rowsAffected: Int(modified),
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )

        case .replaceOne(let collection, let filter, let replacement):
            let cmd = """
                {"update": "\(escapeJsonString(collection))", \
                "updates": [{"q": \(filter), "u": \(replacement), "multi": false}]}
                """
            let result = try await conn.runCommand(cmd, database: db)
            let modified = (result.first?["nModified"] as? Int64)
                ?? (result.first?["nModified"] as? Int).map(Int64.init)
                ?? 0
            return QueryResult(
                columns: ["modifiedCount"],
                columnTypes: [.integer(rawType: "Int64")],
                rows: [[String(modified)]],
                rowsAffected: Int(modified),
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )

        case .deleteOne(let collection, let filter):
            let deleted = try await conn.deleteOne(database: db, collection: collection, filter: filter)
            return QueryResult(
                columns: ["deletedCount"],
                columnTypes: [.integer(rawType: "Int64")],
                rows: [[String(deleted)]],
                rowsAffected: Int(deleted),
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )

        case .deleteMany(let collection, let filter):
            let cmd = """
                {"delete": "\(escapeJsonString(collection))", \
                "deletes": [{"q": \(filter), "limit": 0}]}
                """
            let result = try await conn.runCommand(cmd, database: db)
            let deleted = (result.first?["n"] as? Int64)
                ?? (result.first?["n"] as? Int).map(Int64.init)
                ?? 0
            return QueryResult(
                columns: ["deletedCount"],
                columnTypes: [.integer(rawType: "Int64")],
                rows: [[String(deleted)]],
                rowsAffected: Int(deleted),
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )

        case .createIndex(let collection, let keys, let options):
            var indexDoc = "{\"key\": \(keys)"
            if let opts = options {
                indexDoc += ", " + String(opts.dropFirst())
            } else {
                indexDoc += "}"
            }
            let cmd = """
                {"createIndexes": "\(escapeJsonString(collection))", \
                "indexes": [\(indexDoc)]}
                """
            let result = try await conn.runCommand(cmd, database: db)
            return buildQueryResult(from: result, startTime: startTime)

        case .dropIndex(let collection, let indexName):
            let cmd = """
                {"dropIndexes": "\(escapeJsonString(collection))", \
                "index": "\(escapeJsonString(indexName))"}
                """
            let result = try await conn.runCommand(cmd, database: db)
            return buildQueryResult(from: result, startTime: startTime)

        case .drop(let collection):
            let cmd = "{\"drop\": \"\(escapeJsonString(collection))\"}"
            let result = try await conn.runCommand(cmd, database: db)
            return buildQueryResult(from: result, startTime: startTime)

        default:
            throw DatabaseError.queryFailed("Unexpected operation in write dispatch")
        }
    }
}

// MARK: - Result Building

private extension MongoDBDriver {
    func buildQueryResult(from documents: [[String: Any]], startTime: Date) -> QueryResult {
        if documents.isEmpty {
            return QueryResult(
                columns: [],
                columnTypes: [],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime),
                error: nil
            )
        }

        let columns = BsonDocumentFlattener.unionColumns(from: documents)
        let bsonTypes = BsonDocumentFlattener.columnTypes(for: columns, documents: documents)
        let columnTypes = bsonTypes.map { ColumnType(fromBsonType: $0) }
        let rows = BsonDocumentFlattener.flatten(documents: documents, columns: columns)

        return QueryResult(
            columns: columns,
            columnTypes: columnTypes,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime),
            error: nil
        )
    }
}

// MARK: - JSON Helpers

private extension MongoDBDriver {
    /// Escape a string for safe embedding inside a JSON string value.
    /// Handles quotes, backslashes, and control characters.
    func escapeJsonString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for char in value {
            switch char {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(char)
            }
        }
        return result
    }
}
