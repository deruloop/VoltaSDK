//
//  ChatTurn.swift
//  AIProviderKit
//
//  Un turno di conversazione fornito DALL'APP al framework (D12).
//
//  Il framework è "stateless, transcript-transparent": non ricorda mai nulla
//  tra una chiamata e l'altra, ma ogni chiamata può trasportare la storia
//  della conversazione fornita dallo sviluppatore. Così:
//   - la proprietà della conversazione (persistenza, editing, trimming)
//     resta all'app, non al framework;
//   - ogni chiamata è autocontenuta, quindi QUALSIASI provider della catena
//     può rispondere a qualsiasi turno → il cambio di provider a metà
//     conversazione (quota PCC esaurita, rate limit on-device) è gratuito,
//     gestito dal normale fallback per-chiamata.
//

import Foundation

/// Un messaggio di una conversazione precedente, passato come contesto.
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
