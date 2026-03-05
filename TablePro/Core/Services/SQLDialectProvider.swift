//
//  SQLDialectProvider.swift
//  TablePro
//
//  Created by OpenCode on 1/17/26.
//

import Foundation

// MARK: - MySQL/MariaDB Dialect

struct MySQLDialect: SQLDialectProvider {
    let identifierQuote = "`"

    let keywords: Set<String> = [
        // Core DML keywords
        "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS",
        "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS", "ALIAS",
        "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",

        // DDL keywords
        "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
        "ADD", "MODIFY", "CHANGE", "COLUMN", "RENAME",

        // Data types
        "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",

        // Control flow
        "CASE", "WHEN", "THEN", "ELSE", "END", "IF", "IFNULL", "COALESCE",

        // Set operations
        "UNION", "INTERSECT", "EXCEPT",

        // MySQL-specific
        "FORCE", "USE", "IGNORE", "STRAIGHT_JOIN", "DUAL",
        "SHOW", "DESCRIBE", "DESC", "EXPLAIN"
    ]

    let functions: Set<String> = [
        // Aggregate
        "COUNT", "SUM", "AVG", "MAX", "MIN", "GROUP_CONCAT",

        // String
        "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
        "TRIM", "LTRIM", "RTRIM", "REPLACE",

        // Date/Time
        "NOW", "CURDATE", "CURTIME", "DATE", "TIME", "YEAR", "MONTH", "DAY",
        "DATE_ADD", "DATE_SUB", "DATEDIFF", "TIMESTAMPDIFF",

        // Math
        "ROUND", "CEIL", "FLOOR", "ABS", "MOD", "POW", "SQRT",

        // Conversion
        "CAST", "CONVERT"
    ]

    let dataTypes: Set<String> = [
        // Integer types
        "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",

        // Decimal types
        "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",

        // String types
        "CHAR", "VARCHAR", "TEXT", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT",
        "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB",

        // Date/Time types
        "DATE", "TIME", "DATETIME", "TIMESTAMP", "YEAR",

        // Other types
        "ENUM", "SET", "JSON", "BOOL", "BOOLEAN"
    ]
}

// MARK: - PostgreSQL Dialect

struct PostgreSQLDialect: SQLDialectProvider {
    let identifierQuote = "\""

    let keywords: Set<String> = [
        // Core DML keywords
        "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
        "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "ILIKE", "BETWEEN", "AS",
        "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "FETCH", "FIRST", "ROWS", "ONLY",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",

        // DDL keywords
        "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
        "ADD", "MODIFY", "COLUMN", "RENAME",

        // Data attributes
        "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",

        // Control flow
        "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF",

        // Set operations
        "UNION", "INTERSECT", "EXCEPT",

        // PostgreSQL-specific
        "RETURNING", "WITH", "RECURSIVE", "AS", "MATERIALIZED",
        "EXPLAIN", "ANALYZE", "VERBOSE",
        "WINDOW", "OVER", "PARTITION",
        "LATERAL", "ORDINALITY"
    ]

    let functions: Set<String> = [
        // Aggregate
        "COUNT", "SUM", "AVG", "MAX", "MIN", "STRING_AGG", "ARRAY_AGG",

        // String
        "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
        "TRIM", "LTRIM", "RTRIM", "REPLACE", "SPLIT_PART",

        // Date/Time
        "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
        "DATE_TRUNC", "EXTRACT", "AGE", "TO_CHAR", "TO_DATE",

        // Math
        "ROUND", "CEIL", "CEILING", "FLOOR", "ABS", "MOD", "POW", "POWER", "SQRT",

        // Conversion
        "CAST", "TO_NUMBER", "TO_TIMESTAMP",

        // JSON
        "JSON_BUILD_OBJECT", "JSON_AGG", "JSONB_BUILD_OBJECT"
    ]

    let dataTypes: Set<String> = [
        // Integer types
        "INTEGER", "INT", "SMALLINT", "BIGINT", "SERIAL", "BIGSERIAL", "SMALLSERIAL",

        // Decimal types
        "DECIMAL", "NUMERIC", "REAL", "DOUBLE", "PRECISION",

        // String types
        "CHAR", "CHARACTER", "VARCHAR", "TEXT",

        // Date/Time types
        "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL",

        // Other types
        "BOOLEAN", "BOOL", "JSON", "JSONB", "UUID", "BYTEA", "ARRAY"
    ]
}

// MARK: - SQLite Dialect

struct SQLiteDialect: SQLDialectProvider {
    let identifierQuote = "`"

    let keywords: Set<String> = [
        // Core DML keywords
        "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS",
        "ON", "AND", "OR", "NOT", "IN", "LIKE", "GLOB", "BETWEEN", "AS",
        "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",

        // DDL keywords
        "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "TRIGGER",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
        "ADD", "COLUMN", "RENAME",

        // Data attributes
        "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL",

        // Control flow
        "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "IFNULL", "NULLIF",

        // Set operations
        "UNION", "INTERSECT", "EXCEPT",

        // SQLite-specific
        "AUTOINCREMENT", "WITHOUT", "ROWID", "PRAGMA",
        "REPLACE", "ABORT", "FAIL", "IGNORE", "ROLLBACK",
        "TEMP", "TEMPORARY", "VACUUM", "EXPLAIN", "QUERY", "PLAN"
    ]

    let functions: Set<String> = [
        // Aggregate
        "COUNT", "SUM", "AVG", "MAX", "MIN", "GROUP_CONCAT", "TOTAL",

        // String
        "LENGTH", "SUBSTR", "SUBSTRING", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM",
        "REPLACE", "INSTR", "PRINTF",

        // Date/Time
        "DATE", "TIME", "DATETIME", "JULIANDAY", "STRFTIME",

        // Math
        "ABS", "ROUND", "RANDOM", "MIN", "MAX",

        // Conversion
        "CAST", "TYPEOF",

        // Other
        "COALESCE", "IFNULL", "NULLIF", "HEX", "QUOTE"
    ]

    let dataTypes: Set<String> = [
        // SQLite's storage classes
        "INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC",

        // Type affinities
        "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
        "UNSIGNED", "BIG", "INT2", "INT8",
        "CHARACTER", "VARCHAR", "VARYING", "NCHAR", "NATIVE",
        "NVARCHAR", "CLOB",
        "DOUBLE", "PRECISION", "FLOAT",
        "DECIMAL", "BOOLEAN", "DATE", "DATETIME"
    ]
}

// MARK: - MSSQL Dialect

struct MSSQLDialect: SQLDialectProvider {
    let identifierQuote = "["

    let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
        "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS",
        "ORDER", "BY", "GROUP", "HAVING", "TOP", "OFFSET", "FETCH", "NEXT", "ROWS", "ONLY",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",

        "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
        "ADD", "COLUMN", "RENAME", "EXEC",

        "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
        "IDENTITY", "NOLOCK", "WITH", "ROWCOUNT", "NEWID",

        "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF", "IIF",

        "UNION", "INTERSECT", "EXCEPT",

        "DECLARE", "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION",
        "PRINT", "GO", "EXEC", "EXECUTE",
        "OVER", "PARTITION", "ROW_NUMBER", "RANK", "DENSE_RANK",
        "RETURNING", "OUTPUT", "INSERTED", "DELETED"
    ]

    let functions: Set<String> = [
        "COUNT", "SUM", "AVG", "MAX", "MIN", "STRING_AGG",

        "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LEN", "LOWER", "UPPER",
        "TRIM", "LTRIM", "RTRIM", "REPLACE", "CHARINDEX", "PATINDEX",
        "STUFF", "FORMAT",

        "GETDATE", "GETUTCDATE", "SYSDATETIME", "CURRENT_TIMESTAMP",
        "DATEADD", "DATEDIFF", "DATENAME", "DATEPART",
        "CONVERT", "CAST", "FORMAT",

        "ROUND", "CEILING", "FLOOR", "ABS", "POWER", "SQRT", "RAND",

        "ISNULL", "ISNUMERIC", "ISDATE", "COALESCE", "NEWID",
        "OBJECT_ID", "OBJECT_NAME", "SCHEMA_NAME", "DB_NAME",
        "SCOPE_IDENTITY", "@@IDENTITY", "@@ROWCOUNT"
    ]

    let dataTypes: Set<String> = [
        "INT", "INTEGER", "TINYINT", "SMALLINT", "BIGINT",

        "DECIMAL", "NUMERIC", "FLOAT", "REAL", "MONEY", "SMALLMONEY",

        "CHAR", "VARCHAR", "NCHAR", "NVARCHAR", "TEXT", "NTEXT",

        "BINARY", "VARBINARY", "IMAGE",

        "DATE", "TIME", "DATETIME", "DATETIME2", "SMALLDATETIME", "DATETIMEOFFSET",

        "BIT", "UNIQUEIDENTIFIER", "XML", "SQL_VARIANT",
        "ROWVERSION", "TIMESTAMP", "HIERARCHYID"
    ]
}

// MARK: - Dialect Factory

struct SQLDialectFactory {
    /// Create a dialect provider for the given database type
    static func createDialect(for databaseType: DatabaseType) -> SQLDialectProvider {
        switch databaseType {
        case .mysql, .mariadb:
            return MySQLDialect()
        case .postgresql, .redshift:
            return PostgreSQLDialect()
        case .sqlite:
            return SQLiteDialect()
        case .mongodb:
            return SQLiteDialect()  // Placeholder until MongoDB dialect is implemented
        case .redis:
            return SQLiteDialect()  // Placeholder until Redis dialect is implemented
        case .mssql:
            return MSSQLDialect()
        }
    }
}
