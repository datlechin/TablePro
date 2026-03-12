import Foundation

public struct SQLDialectDescriptor: Sendable {
    public let identifierQuote: String
    public let keywords: Set<String>
    public let functions: Set<String>
    public let dataTypes: Set<String>

    public init(
        identifierQuote: String,
        keywords: Set<String>,
        functions: Set<String>,
        dataTypes: Set<String>
    ) {
        self.identifierQuote = identifierQuote
        self.keywords = keywords
        self.functions = functions
        self.dataTypes = dataTypes
    }
}
