//
//  AIPlaygroundView.swift
//  AIProviderKitUI
//
//  Vista prompt→risposta pronta all'uso, con indicazione di quale provider
//  ha risposto e a quale livello di privacy. Ogni invio è una chiamata
//  indipendente (il multi-turno con memoria è in roadmap nel core: questa
//  vista mostra lo storico solo visivamente).
//

import SwiftUI
import AIProviderKit

/// Un singolo scambio prompt → risposta, con provenienza.
public struct PlaygroundExchange: Identifiable, Sendable {
    public let id = UUID()
    public let prompt: String
    public let response: AIResponse
}

/// Playground minimale che lo sviluppatore può usare così com'è o come
/// riferimento per la propria UI (tutta la logica passa da `respondDetailed`).
public struct AIPlaygroundView: View {
    private let orchestrator: AIOrchestrator
    private let instructions: String?
    private let placeholder: String

    @State private var prompt = ""
    @State private var exchanges: [PlaygroundExchange] = []
    @State private var errorText: String?
    @State private var isLoading = false

    public init(
        orchestrator: AIOrchestrator,
        instructions: String? = nil,
        placeholder: String = "Scrivi un prompt…"
    ) {
        self.orchestrator = orchestrator
        self.instructions = instructions
        self.placeholder = placeholder
    }

    public var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(exchanges) { exchange in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(exchange.prompt)
                                    .font(.body.weight(.medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 6) {
                                    Text(exchange.response.provider.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    PrivacyLevelBadge(level: exchange.response.privacyLevel)
                                }
                                Text(exchange.response.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                            .id(exchange.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: exchanges.count) {
                    if let last = exchanges.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                TextField(placeholder, text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(isLoading || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        prompt = ""
        errorText = nil
        isLoading = true

        Task {
            do {
                let response = try await orchestrator.respondDetailed(
                    to: text,
                    instructions: instructions
                )
                exchanges.append(PlaygroundExchange(prompt: text, response: response))
            } catch let error as ProviderError {
                errorText = Self.describe(error)
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }

    private static func describe(_ error: ProviderError) -> String {
        switch error {
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Limite di richieste raggiunto, riprova tra \(Int(retryAfter))s"
            }
            return "Limite di richieste raggiunto"
        case .unauthorized:
            return "API key non valida o mancante"
        case .network(let code):
            return "Errore di rete (\(code))"
        case .emptyResponse:
            return "Risposta vuota dal provider"
        case .encoding(let detail), .decoding(let detail):
            return "Errore dati: \(detail)"
        case .api(let message, _):
            return "Errore del provider: \(message)"
        case .contextWindowExceeded:
            return "Prompt troppo lungo per la finestra di contesto"
        case .guardrailViolation:
            return "Contenuto bloccato dai guardrail di sicurezza"
        case .unsupportedLanguage:
            return "Lingua non supportata dal modello"
        case .generation(let detail):
            return "Errore di generazione: \(detail)"
        case .noProviderAvailable:
            return "Nessun provider disponibile"
        case .privacyRestricted:
            return "Bloccato dalla policy di privacy"
        case .cancelled:
            return "Operazione annullata"
        }
    }
}
