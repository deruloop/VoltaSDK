//
//  ChatTurn.swift
//  AIProviderKit
//
//  A conversation turn supplied BY THE APP to the framework (D12).
//
//  The framework is "stateless, transcript-transparent": it never remembers
//  anything between calls, but every call can carry the conversation
//  history supplied by the developer. As a result:
//   - ownership of the conversation (persistence, editing, trimming)
//     stays with the app, not the framework;
//   - every call is self-contained, so ANY provider in the chain can
//     answer any turn → switching provider mid-conversation (PCC quota
//     exhausted, on-device rate limit) is free, handled by the normal
//     per-call fallback.
//

import Foundation

/// A message from a previous conversation, passed as context.
public struct ChatTurn: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }

    public static func user(_ text: String) -> ChatTurn {
        ChatTurn(role: .user, text: text)
    }

    public static func assistant(_ text: String) -> ChatTurn {
        ChatTurn(role: .assistant, text: text)
    }
}
