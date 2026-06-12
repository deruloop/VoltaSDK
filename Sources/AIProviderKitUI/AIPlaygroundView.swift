//
//  AIPlaygroundView.swift
//  AIProviderKitUI
//
//  Vista prompt→risposta pronta all'uso, con indicazione di quale provider
//  ha risposto e a quale livello di privacy.
//
//  Dimostra il pattern D12 ("stateless core, transcript-transparent"):
//  questa vista interpreta il ruolo dello SVILUPPATORE — possiede la storia
//  della conversazione e la passa a ogni chiamata via `history:`. Il
//  framework non memorizza nulla; ogni chiamata è autocontenuta, quindi i
//  follow-up funzionano anche se il provider cambia tra un turno e l'altro.
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
    @State private var contextUsage: ContextUsage?

    public init(
        orchestrator: AIOrchestrator,
        instructions: String? = nil,
        placeholder: String = "Scrivi un prompt…"
    ) {
        self.orchestrator = orchestrator
        self.instructions = instructions
        self.placeholder = placeholder
    }

    /// La storia che verrà inviata col prossimo turno (ruolo "sviluppatore").
    private var conversationHistory: [ChatTurn] {
        exchanges.flatMap { exchange in
            [.user(exchange.prompt), .assistant(exchange.response.text)]
        }
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Conversazione (\(exchanges.count) turni)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let contextUsage {
                    // Pressione sulla finestra del provider che risponderebbe
                    // ora (D13): è il segnale per accorciare/riassumere (D12).
                    Text("· contesto \(Int(contextUsage.fraction * 100))% di \(contextUsage.contextSize)")
                        .font(.caption)
                        .foregroundStyle(contextUsage.fraction > 0.8 ? .orange : .secondary)
                }
                Spacer()
                Button("Nuova conversazione", systemImage: "plus.bubble") {
                    exchanges.removeAll()
                    errorText = nil
                    contextUsage = nil
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(exchanges.isEmpty)
            }
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

        // Fotografa la storia PRIMA della chiamata: è l'app (qui la vista)
        // a possederla e fornirla — il framework non ricorda nulla (D12).
        let history = conversationHistory

        Task {
            do {
                let response = try await orchestrator.respondDetailed(
                    to: text,
                    instructions: instructions,
                    history: history
                )
                exchanges.append(PlaygroundExchange(prompt: text, response: response))
                contextUsage = await orchestrator.contextUsage(
                    instructions: instructions,
                    history: conversationHistory
                )
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
