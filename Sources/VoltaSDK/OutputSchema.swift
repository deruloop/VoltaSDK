//
//  OutputSchema.swift
//  VoltaSDK
//
//  Structured output, D21: the vendor-neutral description of the JSON an
//  app wants back. One schema value feeds three things — guided generation
//  on Apple models (converted to a `DynamicGenerationSchema`), JSON mode on
//  the cloud vendors (exported as JSON Schema in each vendor's dialect), and
//  the SDK's own validator, which is what turns "the model answered" into
//  "the app got the type it asked for" (or a typed failure).
//
//  Deliberately smaller than JSON Schema: the intersection every backend
//  can honour. Objects, strings (with enum / pattern), numbers, integers,
//  booleans, arrays (with bounds), and a named `anyOf` for answers that may
//  take one of several shapes.
//

import Foundation

/// A JSON shape the app expects from a model.
public indirect enum OutputSchema: Sendable, Equatable {
    /// A JSON object with named properties. `name` is required by Apple's
    /// dynamic schemas (it becomes the type name the model sees) and is a
    /// good description everywhere else.
    case object(name: String, description: String? = nil, properties: [Property])
    case string(description: String? = nil, enumeration: [String]? = nil, pattern: String? = nil)
    case number(description: String? = nil)
    case integer(description: String? = nil)
    case boolean(description: String? = nil)
    case array(description: String? = nil, of: OutputSchema, minimumCount: Int? = nil, maximumCount: Int? = nil)
    /// One of several shapes. Each choice should be an object with a
    /// distinct property set so the answer is unambiguous.
    case anyOf(name: String, description: String? = nil, choices: [OutputSchema])

    public struct Property: Sendable, Equatable {
        public let name: String
        public let description: String?
        public let schema: OutputSchema
        /// Optional properties may be absent (or null) in a valid answer.
        public let isOptional: Bool

        public init(_ name: String, description: String? = nil, _ schema: OutputSchema, isOptional: Bool = false) {
            self.name = name
            self.description = description
            self.schema = schema
            self.isOptional = isOptional
        }
    }

    public var description: String? {
        switch self {
        case .object(_, let description, _), .string(let description, _, _),
             .number(let description), .integer(let description),
             .boolean(let description), .array(let description, _, _, _),
             .anyOf(_, let description, _):
            return description
        }
    }

    /// The root type's name (objects and anyOf carry one; scalars get a
    /// generic label).
    public var rootName: String {
        switch self {
        case .object(let name, _, _), .anyOf(let name, _, _): return name
        default: return "Output"
        }
    }
}

// MARK: - JSON Schema export

extension OutputSchema {
    /// Which vendor the JSON Schema is for. The dialects differ in what they
    /// accept: every object gets `additionalProperties: false` and a full
    /// `required` list (OpenAI strict mode and Anthropic both demand it);
    /// string `pattern` is exported only where strict mode supports it and
    /// otherwise enforced by the SDK validator after the call.
    public enum JSONSchemaDialect: Sendable {
        case openAI, anthropic, gemini, generic
    }

    /// The schema as a JSON Schema document (draft 2020-12 subset).
    public func jsonSchema(dialect: JSONSchemaDialect = .generic) -> JSONValue {
        var node: [String: JSONValue] = [:]
        if let description { node["description"] = .string(description) }

        switch self {
        case .object(_, _, let properties):
            node["type"] = "object"
            var members: [String: JSONValue] = [:]
            var required: [JSONValue] = []
            for property in properties {
                var child = property.schema.jsonSchema(dialect: dialect)
                if let description = property.description, child["description"] == nil,
                   case .object(var childMembers) = child {
                    childMembers["description"] = .string(description)
                    child = .object(childMembers)
                }
                if property.isOptional, dialect == .openAI, case .object(var childMembers) = child {
                    // OpenAI strict mode: every property is required; optional
                    // ones are expressed as nullable.
                    if let type = childMembers["type"] {
                        childMembers["type"] = .array([type, "null"])
                    }
                    child = .object(childMembers)
                }
                members[property.name] = child
                if !property.isOptional || dialect == .openAI {
                    required.append(.string(property.name))
                }
            }
            node["properties"] = .object(members)
            node["required"] = .array(required)
            node["additionalProperties"] = false
        case .string(_, let enumeration, let pattern):
            node["type"] = "string"
            if let enumeration { node["enum"] = .array(enumeration.map(JSONValue.string)) }
            if let pattern, dialect == .openAI || dialect == .generic {
                node["pattern"] = .string(pattern)
            }
        case .number:
            node["type"] = "number"
        case .integer:
            node["type"] = "integer"
        case .boolean:
            node["type"] = "boolean"
        case .array(_, let item, let minimum, let maximum):
            node["type"] = "array"
            node["items"] = item.jsonSchema(dialect: dialect)
            // Array bounds are a "numerical constraint" some strict modes
            // reject; the validator enforces them everywhere.
            if dialect == .generic {
                if let minimum { node["minItems"] = .number(Double(minimum)) }
                if let maximum { node["maxItems"] = .number(Double(maximum)) }
            }
        case .anyOf(_, _, let choices):
            node["anyOf"] = .array(choices.map { $0.jsonSchema(dialect: dialect) })
        }
        return .object(node)
    }
}

// MARK: - Validation

/// One way a value failed its schema, with the JSON path to the offender.
public struct SchemaViolation: Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

extension OutputSchema {
    /// Validates a value against the schema. Empty result = valid.
    public func validate(_ value: JSONValue) -> [SchemaViolation] {
        var violations: [SchemaViolation] = []
        validate(value, at: "$", into: &violations)
        return violations
    }

    private func validate(_ value: JSONValue, at path: String, into violations: inout [SchemaViolation]) {
        switch self {
        case .object(_, _, let properties):
            guard case .object(let members) = value else {
                violations.append(.init(path: path, message: "expected an object, got \(value.typeName)"))
                return
            }
            for property in properties {
                let childPath = "\(path).\(property.name)"
                guard let child = members[property.name], !child.isNull else {
                    if !property.isOptional {
                        violations.append(.init(path: childPath, message: "missing required property"))
                    }
                    continue
                }
                property.schema.validate(child, at: childPath, into: &violations)
            }
        case .string(_, let enumeration, let pattern):
            guard case .string(let text) = value else {
                violations.append(.init(path: path, message: "expected a string, got \(value.typeName)"))
                return
            }
            if let enumeration, !enumeration.contains(text) {
                violations.append(.init(path: path, message: "\"\(text)\" is not one of \(enumeration)"))
            }
            if let pattern, (try? Regex(pattern).wholeMatch(in: text)) == nil {
                violations.append(.init(path: path, message: "\"\(text)\" does not match /\(pattern)/"))
            }
        case .number:
            if case .number = value { return }
            violations.append(.init(path: path, message: "expected a number, got \(value.typeName)"))
        case .integer:
            guard case .number(let number) = value else {
                violations.append(.init(path: path, message: "expected an integer, got \(value.typeName)"))
                return
            }
            if number != number.rounded() {
                violations.append(.init(path: path, message: "expected an integer, got \(number)"))
            }
        case .boolean:
            if case .bool = value { return }
            violations.append(.init(path: path, message: "expected a boolean, got \(value.typeName)"))
        case .array(_, let item, let minimum, let maximum):
            guard case .array(let items) = value else {
                violations.append(.init(path: path, message: "expected an array, got \(value.typeName)"))
                return
            }
            if let minimum, items.count < minimum {
                violations.append(.init(path: path, message: "expected at least \(minimum) items, got \(items.count)"))
            }
            if let maximum, items.count > maximum {
                violations.append(.init(path: path, message: "expected at most \(maximum) items, got \(items.count)"))
            }
            for (index, element) in items.enumerated() {
                item.validate(element, at: "\(path)[\(index)]", into: &violations)
            }
        case .anyOf(_, _, let choices):
            // Valid if any choice accepts it; otherwise report the CLOSEST
            // choice's violations, so the repair prompt (and a grader's
            // rationale) talks about the shape the model was attempting.
            // Closest = the choice whose property names overlap the value's
            // keys most, then the fewest violations.
            var best: (overlap: Int, violations: [SchemaViolation])? = nil
            for choice in choices {
                let result = choice.validate(value)
                if result.isEmpty { return }
                let overlap = choice.keyOverlap(with: value)
                if best == nil || overlap > best!.overlap
                    || (overlap == best!.overlap && result.count < best!.violations.count) {
                    best = (overlap, result)
                }
            }
            if let best {
                violations.append(.init(path: path, message: "matches none of the \(choices.count) allowed shapes; closest: \(best.violations.map(\.description).joined(separator: "; "))"))
            }
        }
    }
}

extension OutputSchema {
    /// How many of an object schema's property names the value carries.
    func keyOverlap(with value: JSONValue) -> Int {
        guard case .object(_, _, let properties) = self, let members = value.objectValue else { return 0 }
        return properties.filter { members[$0.name] != nil }.count
    }
}

// MARK: - Prompt rendering

extension OutputSchema {
    /// A compact, human-readable statement of the schema for providers that
    /// have no native structured mode (the prompted fallback): the JSON
    /// Schema itself, which every current model reads fluently.
    public var promptDescription: String {
        "Reply with ONLY a JSON value (no prose, no markdown fences) that conforms to this JSON Schema:\n"
            + jsonSchema(dialect: .generic).serialized(pretty: true)
    }
}

// MARK: - Codable (schemas as data)

/// A compact JSON form so a schema can live in a data file (evaluation
/// tasks, remote configuration) and round-trip losslessly. Objects keep
/// their property ORDER (an array, not a map): Apple's guided generation
/// fills properties in schema order, so order is part of the contract.
///
/// ```json
/// {"type":"object","name":"Ripieno","properties":[
///   {"name":"title","schema":{"type":"string"}},
///   {"name":"items","schema":{"type":"array","items":{...},"min":1}},
///   {"name":"notes","optional":true,"schema":{"type":"string"}}]}
/// {"type":"string","enum":["a","b"],"pattern":"^#[0-9A-Fa-f]{6}$"}
/// {"type":"anyOf","name":"Reply","choices":[{...},{...}]}
/// ```
extension OutputSchema: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, name, description, properties, `enum`, pattern, items, min, max, choices
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let description = try container.decodeIfPresent(String.self, forKey: .description)
        switch type {
        case "object":
            self = .object(
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Output",
                description: description,
                properties: try container.decodeIfPresent([Property].self, forKey: .properties) ?? []
            )
        case "string":
            self = .string(
                description: description,
                enumeration: try container.decodeIfPresent([String].self, forKey: .enum),
                pattern: try container.decodeIfPresent(String.self, forKey: .pattern)
            )
        case "number": self = .number(description: description)
        case "integer": self = .integer(description: description)
        case "boolean": self = .boolean(description: description)
        case "array":
            self = .array(
                description: description,
                of: try container.decode(OutputSchema.self, forKey: .items),
                minimumCount: try container.decodeIfPresent(Int.self, forKey: .min),
                maximumCount: try container.decodeIfPresent(Int.self, forKey: .max)
            )
        case "anyOf":
            self = .anyOf(
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Output",
                description: description,
                choices: try container.decode([OutputSchema].self, forKey: .choices)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown schema type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(description, forKey: .description)
        switch self {
        case .object(let name, _, let properties):
            try container.encode("object", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(properties, forKey: .properties)
        case .string(_, let enumeration, let pattern):
            try container.encode("string", forKey: .type)
            try container.encodeIfPresent(enumeration, forKey: .enum)
            try container.encodeIfPresent(pattern, forKey: .pattern)
        case .number: try container.encode("number", forKey: .type)
        case .integer: try container.encode("integer", forKey: .type)
        case .boolean: try container.encode("boolean", forKey: .type)
        case .array(_, let item, let minimum, let maximum):
            try container.encode("array", forKey: .type)
            try container.encode(item, forKey: .items)
            try container.encodeIfPresent(minimum, forKey: .min)
            try container.encodeIfPresent(maximum, forKey: .max)
        case .anyOf(let name, _, let choices):
            try container.encode("anyOf", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(choices, forKey: .choices)
        }
    }
}

extension OutputSchema.Property: Codable {
    private enum CodingKeys: String, CodingKey { case name, description, schema, optional }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try container.decode(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            try container.decode(OutputSchema.self, forKey: .schema),
            isOptional: try container.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(schema, forKey: .schema)
        if isOptional { try container.encode(true, forKey: .optional) }
    }
}
