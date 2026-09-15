//
//  OutputSchema+FoundationModels.swift
//  VoltaSDK
//
//  The Apple half of structured output (D21): an `OutputSchema` becomes a
//  `DynamicGenerationSchema` tree, then a `GenerationSchema` the session
//  can be handed (`respond(to:schema:)`) — constrained decoding on-device
//  and on PCC, so the answer is well-formed by construction. iOS 26+: the
//  dynamic schema API shipped with the framework's first release.
//

import Foundation
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
extension OutputSchema {

    /// The schema as the framework's `GenerationSchema`, for guided generation.
    public func generationSchema() throws -> GenerationSchema {
        try GenerationSchema(root: dynamicSchema(name: rootName), dependencies: [])
    }

    /// The dynamic-schema tree. Nested objects are inlined (no references),
    /// which the framework accepts for the depths real app schemas reach.
    func dynamicSchema(name: String) -> DynamicGenerationSchema {
        switch self {
        case .object(let objectName, let description, let properties):
            return DynamicGenerationSchema(
                name: objectName.isEmpty ? name : objectName,
                description: description,
                properties: properties.map { property in
                    DynamicGenerationSchema.Property(
                        name: property.name,
                        description: property.description,
                        schema: property.schema.dynamicSchema(name: name + "_" + property.name),
                        isOptional: property.isOptional
                    )
                }
            )
        case .string(let description, let enumeration, _):
            if let enumeration {
                return DynamicGenerationSchema(name: name, description: description, anyOf: enumeration)
            }
            // A `pattern` is NOT forwarded: the system model rejects a
            // `.pattern` guide inside a dynamic schema at generation time
            // ("UnsupportedGuide", observed live on macOS 27). The SDK
            // validator enforces patterns after the call instead. The
            // description keeps the intent visible to the model.
            return DynamicGenerationSchema(type: String.self, guides: [])
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .integer:
            return DynamicGenerationSchema(type: Int.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .array(_, let item, let minimum, let maximum):
            return DynamicGenerationSchema(
                arrayOf: item.dynamicSchema(name: name + "_item"),
                minimumElements: minimum,
                maximumElements: maximum
            )
        case .anyOf(let choiceName, let description, let choices):
            return DynamicGenerationSchema(
                name: choiceName.isEmpty ? name : choiceName,
                description: description,
                anyOf: choices.enumerated().map { index, choice in
                    choice.dynamicSchema(name: "\(name)_choice\(index)")
                }
            )
        }
    }
}

// MARK: - Session helper shared by the session-backed providers

@available(iOS 26.0, macOS 26.0, *)
enum GuidedGeneration {
    /// Runs one guided-generation turn on a session and returns the JSON
    /// text of the generated content. Errors are left to the caller's
    /// mapping (each provider maps its own error families).
    static func respond(
        session: LanguageModelSession,
        prompt: String,
        schema: OutputSchema
    ) async throws -> String {
        let generationSchema = try schema.generationSchema()
        let response = try await session.respond(to: prompt, schema: generationSchema)
        return response.content.jsonString
    }
}
