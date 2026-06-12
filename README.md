# AIProviderKit

Base iOS 26, pronta per la produzione, di un framework che **risolve a runtime
quale modello AI usare** (on-device o cloud) con fallback automatico e
disclosure di privacy. Espone un'API pubblica stabile pensata per essere estesa
su iOS 27 (multi-provider, PCC, Dynamic Profiles) **senza riscrivere il codice
dell'app**.

## Cosa fa in questa versione (iOS 26)

- **Due provider**: on-device (Foundation Models) e developer key (OpenAI).
- **Fallback runtime**: salta i provider indisponibili e scala su errori
  recuperabili (429, rete, context window superato, lingua non supportata).
- **Disclosure di privacy**: quando il fallback scende di livello (es.
  on-device → OpenAI) la policy configurata decide: `.silent`, `.notify`,
  `.askOnPrivacyChange`, `.denyDowngrade`.
- **Errori tipizzati**: 429 → rate limit, 401 → auth, guardrail → terminale, ecc.
- **Gestione disponibilità**: rileva se Apple Intelligence è presente/attivo/pronto.
- **UI opzionale**: il core è headless; `AIProviderKitUI` offre componenti
  SwiftUI pronti e personalizzabili.

## Struttura

| Prodotto | Cosa contiene | Obbligatorio? |
|---|---|---|
| `AIProviderKit` | orchestratore, provider, errori, privacy | sì (il core) |
| `AIProviderKitUI` | `PrivacyLevelBadge`, `ProviderStatusList`, `AIPlaygroundView` | no |
| `AIProviderKitDemoUI` | UI demo condivisa macOS+iOS (`DemoRootView`) | no |
| `AIProviderKitDemo` | app di prova macOS (`swift run AIProviderKitDemo`) | no |

La demo iPhone/iPad è in `Examples/iOSDemo/iOSDemo.xcodeproj`.

## Installazione

Swift Package Manager. Dalla tua app in Xcode:

**Package locale (stessa macchina):** File → Add Package Dependencies… →
Add Local… → seleziona la cartella `AIProvider`. Poi aggiungi il prodotto
`AIProviderKit` al target dell'app (e `AIProviderKitUI` solo se vuoi i
componenti pronti). Nota: una dipendenza locale usa sempre la working copy,
i tag di versione non si applicano.

**Da repository git (consigliato appena pubblicato su un remote):**

```swift
dependencies: [
    .package(url: "<url-del-repo>", from: "1.0.0")
]
```

La versione corrente è **1.0.0** (vedi [CHANGELOG.md](CHANGELOG.md)).

## Uso (senza UI)

### 1. Configurazione (all'avvio dell'app)

```swift
import AIProviderKit

AIOrchestrator.configure {
    $0.enableOnDevice = true
    $0.developerKey = Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String
    $0.developerKeyModel = "gpt-4o-mini"
    $0.preference = .preferOnDevice          // on-device, poi developer key
    $0.privacyDisclosure = .notify { downgrade in
        print("Risposta generata da \(downgrade.provider) (\(downgrade.to))")
    }
}
```

La `developerKey` va iniettata come secret Xcode (`.xcconfig` → `Info.plist`),
non scritta nel codice sorgente.

### 2. Generazione

```swift
let answer = try await AIOrchestrator.active.respond(
    to: "Pianifica un weekend a Roma",
    instructions: "Sei un esperto di viaggi conciso."
)

// Oppure, con provenienza (per mostrare chi ha risposto):
let response = try await AIOrchestrator.active.respondDetailed(to: "…")
print(response.text, response.provider, response.privacyLevel)
```

### Conversazioni multi-turno

Il framework è **stateless**: non ricorda nulla tra una chiamata e l'altra.
La conversazione appartiene all'app, che la passa a ogni chiamata:

```swift
var history: [ChatTurn] = []

let first = try await kit.respond(to: "Pianifica un weekend")
history += [.user("Pianifica un weekend"), .assistant(first)]

// Il follow-up funziona perché la storia viaggia con la chiamata —
// anche se nel frattempo il fallback ha cambiato provider.
let second = try await kit.respond(to: "Modifica il giorno 2", history: history)
```

Ogni chiamata è autocontenuta: se il provider preferito diventa indisponibile
a metà conversazione, il successivo riceve la stessa storia e la conversazione
continua senza interruzioni (con la disclosure di privacy configurata).
Quando e come accorciare la storia resta una scelta dell'app.

### Consapevolezza dei token (iOS/macOS 26.4+)

Il framework fa un **pre-flight** automatico: se sa che la chiamata non può
stare nella finestra di contesto di un provider, lo salta senza pagare una
generazione destinata a fallire (stessa semantica di `.contextWindowExceeded`).
Su 26.0–26.3 il conteggio on-device non è disponibile e resta il solo
comportamento reattivo.

Per decidere quando accorciare o riassumere la storia:

```swift
if let usage = await kit.contextUsage(history: history), usage.fraction > 0.8 {
    // Tocca all'app: tronca i turni più vecchi, o riassumili.
}
```

`usage` riporta token usati, finestra e provider risolto. È `nil` se il
provider non sa contare (mai una stima spacciata per conteggio).

### 3. Risoluzione senza esecuzione (il primitivo)

```swift
let provider = try await AIOrchestrator.active.resolveProvider()
// Su iOS 27 questo diventerà `preferred(_ need:)` e restituirà un
// LanguageModel da passare a un Dynamic Profile nativo.
```

### 4. Istanza esplicita (senza stato globale)

```swift
var config = AIConfiguration()
config.developerKey = key
let kit = AIOrchestrator(configuration: config)
let answer = try await kit.respond(to: "...")
```

## Uso (con i componenti opzionali)

```swift
import AIProviderKitUI

// Stato della catena di fallback (per debug o impostazioni):
ProviderStatusList(orchestrator: kit)

// Playground conversazionale pronto all'uso, con badge di privacy.
// Possiede la propria storia e la passa a ogni chiamata (pattern D12):
AIPlaygroundView(orchestrator: kit, instructions: "Sii conciso.")
```

Le righe (`ProviderStatusRow`) e i badge (`PrivacyLevelBadge`) sono pubblici:
si possono ricomporre in layout completamente custom usando
`providerStatuses()` e `respondDetailed()` del core.

## App di prova

**macOS:**

```bash
swift run AIProviderKitDemo
```

**iPhone / iPad:** aprire `Examples/iOSDemo/iOSDemo.xcodeproj` e fare Run su un
device o su un simulatore con runtime iOS 26. Su un device con Apple
Intelligence il provider on-device è reale; altrimenti la lista mostra il
motivo di indisponibilità e il fallback passa alla developer key.
(Per il device fisico: impostare il team in Signing & Capabilities.)

Entrambe le demo usano la stessa `DemoRootView` (layout adattivo: split su
macOS, tab su iOS) con: configurazione live (key, modello, preferenza), stato
della catena di fallback con i motivi reali, playground con indicazione del
provider che ha risposto e log dei downgrade di privacy.

## Test

```bash
swift test   # 23 test: fallback, privacy, risoluzione, parsing
```

## Mappatura verso iOS 27

| iOS 26 (oggi)                     | iOS 27 (estensione)                              |
|-----------------------------------|--------------------------------------------------|
| `OnDeviceProvider`                | invariato                                        |
| `OpenAIProvider` (URLSession)     | provider conforme al protocollo `LanguageModel`  |
| `ModelPreference` (4 casi)        | catena di fallback per-bisogno + quote PCC       |
| `resolveProvider()`               | `preferred(_ need:)` per i Dynamic Profiles      |
| `PrivacyDisclosure` (già attiva)  | invariata, estesa al livello `appleCloud` (PCC)  |
| —                                 | `PrivateCloudComputeProvider`                    |
| —                                 | provider utente (Gemini/Claude) + ModelPicker    |

L'API pubblica (`configure`, `respond`, `resolveProvider`) non cambia.

## Requisiti

- iOS 26 / macOS 26, Swift 6.2
- Per on-device: device con Apple Intelligence
