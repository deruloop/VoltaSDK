//
//  JSONValue.swift
//  VoltaSDK
//
//  A small, dependency-free JSON model. Structured output (D21) needs to
//  look INSIDE a model's answer before handing it to the app — validate it
//  against a schema, name what is wrong, feed that back for a repair — and
//  `Any`-typed `JSONSerialization` trees are hostile to that. This enum is
//  the shape every structured path speaks: providers return it, the schema
//  validates it, the app decodes it into its own `Decodable` types.
//

import Foundation

/// A JSON document as a value.
public indirect enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Accessors

    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// A short type name for diagnostics ("string", "object", ...).
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    // MARK: Parsing / serialization

    /// Parses a JSON document. Top-level scalars are accepted (RFC 8259).
    public init(parsing text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw StructuredOutputError.invalidJSON("Text is not valid UTF-8")
        }
        try self.init(parsing: data)
    }

    public init(parsing data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw StructuredOutputError.invalidJSON(error.localizedDescription)
        }
        self = Self.from(foundation: object)
    }

    /// Serialized JSON text. `sorted` keeps output stable (tests, hashing).
    public func serialized(pretty: Bool = false, sorted: Bool = true) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed]
        if pretty { options.insert(.prettyPrinted) }
        if sorted { options.insert(.sortedKeys) }
        guard let data = try? JSONSerialization.data(withJSONObject: foundationObject, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }

    /// Decodes this value into a `Decodable` type via `JSONDecoder`.
    public func decode<T: Decodable>(_ type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = Data(serialized().utf8)
        return try decoder.decode(type, from: data)
    }

    // MARK: Foundation bridging

    static func from(foundation object: Any) -> JSONValue {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // JSONSerialization decodes booleans as NSNumber; the CF type id
            // tells booleans apart from numeric zero/one.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(from(foundation:)))
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues(from(foundation:)))
        default:
            return .string(String(describing: object))
        }
    }

    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            // Whole numbers serialize without a fractional part.
            if value == value.rounded(), abs(value) < 1e15 { return Int64(value) }
            return value
        case .string(let value): return value
        case .array(let items): return items.map(\.foundationObject)
        case .object(let members): return members.mapValues(\.foundationObject)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
                     ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Codable (so app types can embed it)

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let items): try container.encode(items)
        case .object(let members): try container.encode(members)
        }
    }
}

// MARK: - Lenient extraction

extension JSONValue {
    /// Finds the JSON object a model most likely meant, tolerating prose or
    /// a ```json fence around it: the substring from the first `{` to the
    /// last `}`. Returns the parsed value and whether anything surrounded
    /// the object (a signal the answer was not "JSON only").
    ///
    /// This is the parser tolerance real apps ship; the strict path is
    /// `init(parsing:)`.
    public static func extractObject(from text: String) throws -> (value: JSONValue, hadSurroundingText: Bool) {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else {
            throw StructuredOutputError.noJSONFound
        }
        let slice = String(text[open...close])
        let value = try JSONValue(parsing: slice)
        let outside = text[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            + text[text.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare code fence is formatting, not prose.
        let fenceOnly = outside.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return (value, !fenceOnly)
    }
}
