import Foundation

public struct ConnectionField: Codable, Sendable {
    public struct IntRange: Codable, Sendable, Equatable {
        public let lowerBound: Int
        public let upperBound: Int

        public init(_ range: ClosedRange<Int>) {
            self.lowerBound = range.lowerBound
            self.upperBound = range.upperBound
        }

        public init(lowerBound: Int, upperBound: Int) {
            precondition(lowerBound <= upperBound, "IntRange: lowerBound must be <= upperBound")
            self.lowerBound = lowerBound
            self.upperBound = upperBound
        }

        public var closedRange: ClosedRange<Int> { lowerBound...upperBound }

        private enum CodingKeys: String, CodingKey {
            case lowerBound, upperBound
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let lower = try container.decode(Int.self, forKey: .lowerBound)
            let upper = try container.decode(Int.self, forKey: .upperBound)
            guard lower <= upper else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "IntRange lowerBound (\(lower)) must be <= upperBound (\(upper))"
                    )
                )
            }
            self.lowerBound = lower
            self.upperBound = upper
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(lowerBound, forKey: .lowerBound)
            try container.encode(upperBound, forKey: .upperBound)
        }
    }

    public enum FieldType: Codable, Sendable, Equatable {
        case text
        case secure
        case dropdown(options: [DropdownOption])
        case number
        case toggle
        case stepper(range: IntRange)
    }

    public struct DropdownOption: Codable, Sendable, Equatable {
        public let value: String
        public let label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public let id: String
    public let label: String
    public let placeholder: String
    public let isRequired: Bool
    public let defaultValue: String?
    public let fieldType: FieldType

    /// Backward-compatible convenience: true when fieldType is .secure
    public var isSecure: Bool {
        if case .secure = fieldType { return true }
        return false
    }

    public init(
        id: String,
        label: String,
        placeholder: String = "",
        required: Bool = false,
        secure: Bool = false,
        defaultValue: String? = nil,
        fieldType: FieldType? = nil
    ) {
        self.id = id
        self.label = label
        self.placeholder = placeholder
        self.isRequired = required
        self.defaultValue = defaultValue
        self.fieldType = fieldType ?? (secure ? .secure : .text)
    }
}
