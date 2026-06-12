# AIProviderKit

Framework Swift che **risolve a runtime quale modello AI usare** — on-device
(Apple Intelligence) o cloud — con fallback automatico, disclosure di privacy
e conversazioni multi-turno. L'app chiede una risposta; il framework sceglie il
modello giusto in base a disponibilità, preferenza, finestra di contesto e
policy di privacy.

Non è un framework di agenti: non possiede sessioni né conversazioni. Il suo
unico mestiere è la **risoluzione del modello**, pensata per estendersi a
iOS 27 (multi-provider, Private Cloud Compute, Dynamic Profiles) **senza
cambiare l'API**.

## Supporto versioni

| OS | Cosa funziona |
|---|---|
| **iOS / macOS 26.0+** | Tutto il core: catena di fallback, errori tipizzati, disclosure di privacy, conversazioni multi-turno, componenti UI opzionali. Gestione del contesto *reattiva* (errore → fallback). |
| **iOS / macOS 26.4+** | In più, si attiva da solo il tier *token-aware*: conteggio esatto dei token on-device, pre-flight automatico sulla finestra di contesto, `contextUsage` per sapere quanto è piena. |
| **iOS 27** | In sviluppo (multi-provider, PCC, bridge per i Dynamic Profiles). Arriverà come aggiornamento additivo della serie 1.x: stessa API, nessuna riscrittura. |

Requisiti: Swift 6.2 / Xcode 26. Il modello on-device richiede un device con
Apple Intelligence (rilevato a runtime: se assente, il framework lo esclude e
spiega il perché).

## Installazione (Swift Package Manager)

**Da repository git:**

```swift
dependencies: [
    .package(url: "<url-del-repo>", from: "1.0.0")
]
```

In Xcode: File → Add Package Dependencies… → incolla l'URL → aggiungi il
prodotto **`AIProviderKit`** al target dell'app. Aggiungi **`AIProviderKitUI`**
solo se vuoi i componenti SwiftUI pronti: il core è completamente utilizzabile
senza UI.

**Package locale (stessa macchina):** File → Add Package Dependencies… →
Add Local… → seleziona la cartella del package. Nota: una dipendenza locale usa
sempre la working copy, i tag di versione non si applicano.

La versione corrente è **1.0.0** (vedi [CHANGELOG.md](CHANGELOG.md)).

## Uso

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

### 3. Conversazioni multi-turno

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

### 4. Consapevolezza dei token (26.4+)

Il framework fa un **pre-flight** automatico: se sa che la chiamata non può
stare nella finestra di contesto di un provider, lo salta senza pagare una
generazione destinata a fallire. Su 26.0–26.3 il conteggio on-device non è
disponibile e resta il solo comportamento reattivo.

```swift
if let usage = await kit.contextUsage(history: history), usage.fraction > 0.8 {
    // Tocca all'app: tronca i turni più vecchi, o riassumili.
}
```

`usage` è `nil` se il provider risolto non sa contare (mai una stima spacciata
per conteggio).

### 5. Risoluzione senza esecuzione (il primitivo)

```swift
let provider = try await AIOrchestrator.active.resolveProvider()
// Su iOS 27 questo diventerà `preferred(_ need:)` e restituirà un
// LanguageModel da passare a un Dynamic Profile nativo.
```

### 6. Istanza esplicita (senza stato globale)

```swift
var config = AIConfiguration()
config.developerKey = key
let kit = AIOrchestrator(configuration: config)
let answer = try await kit.respond(to: "...")
```

## UI opzionale (`AIProviderKitUI`)

```swift
import AIProviderKitUI

// Stato della catena di fallback (per debug o impostazioni):
ProviderStatusList(orchestrator: kit)

// Playground conversazionale pronto all'uso, con badge di privacy
// e indicatore di pressione sul contesto:
AIPlaygroundView(orchestrator: kit, instructions: "Sii conciso.")
```

Le righe (`ProviderStatusRow`) e i badge (`PrivacyLevelBadge`) sono pubblici:
si possono ricomporre in layout custom usando `providerStatuses()` e
`respondDetailed()` del core.

## App di prova

**macOS:**

```bash
swift run AIProviderKitDemo
```

**iPhone / iPad:** aprire `Examples/iOSDemo/iOSDemo.xcodeproj` e fare Run su un
device o su un simulatore con runtime iOS 26. Su un device con Apple
Intelligence il provider on-device è reale; altrimenti la lista mostra il
motivo di indisponibilità e il fallback passa alla developer key.

## Test

```bash
swift test   # 34 test: fallback, privacy, conversazioni, token, parsing
```

## Per chi lavora sul framework

La documentazione interna è in `docs/`:
- [docs/iOS26-Implementation.md](docs/iOS26-Implementation.md) — come è
  implementata la base iOS 26 / 26.4 (decisioni, API stabile, verifica).
- [docs/iOS27-Design.md](docs/iOS27-Design.md) — il design dell'estensione
  iOS 27 (non ancora implementata).
- [docs/iOS27-OpenQuestions.md](docs/iOS27-OpenQuestions.md) — le domande
  aperte che bloccano l'implementazione iOS 27.
