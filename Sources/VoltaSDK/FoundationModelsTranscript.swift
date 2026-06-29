//
//  FoundationModelsTranscript.swift
//  VoltaSDK
//
//  Shared construction of a native Foundation Models `Transcript` from the
//  app-supplied conversation history (D12).
//
//  Every provider backed by an Apple `LanguageModel` rebuilds the same
//  transcript shape: on-device today, Private Cloud Compute on iOS 27, and
//  any future system-hosted model. Keeping the mapping in one place means the
//  model always sees the conversation exactly the same way, regardless of
//  which Apple backend answers.
//

import Foundation
import FoundationModels

enum FoundationModelsTranscript {

    /// Maps instructions + history (D12) into native `Transcript` entries.
    static func entries(
        instructions: String?,
        history: [ChatTurn]
    ) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []
        if let instructions, !instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: []
            )))
        }
        for turn in history {
            switch turn.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(content: turn.text))]
                )))
            case .assistant:
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: turn.text))]
                )))
            }
        }
        return entries
    }
}
