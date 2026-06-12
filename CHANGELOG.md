# Changelog

Tutte le modifiche rilevanti del package. Versioning: [SemVer](https://semver.org).
La promessa di stabilità (CLAUDE.md §8, D3): le estensioni iOS 27 saranno
additive sulla stessa API — restano nella serie 1.x.

## [1.0.0] — 2026-06-12

Prima release. Base iOS 26 / macOS 26, Swift 6.2.

### Core (`AIProviderKit`)
- `AIOrchestrator`: catena di fallback runtime tra provider, con errori
  tipizzati (`ProviderError`) e distinzione recuperabile/terminale.
- Provider inclusi: `OnDeviceProvider` (Foundation Models, Apple Intelligence)
  e `OpenAIProvider` (developer key, Chat Completions).
- Disclosure di privacy sul downgrade (`PrivacyDisclosure`):
  `.silent` / `.notify` / `.askOnPrivacyChange` / `.denyDowngrade` (D10).
- Conversazioni multi-turno "transcript-transparent" (D12): il core è
  stateless, l'app passa la storia (`history: [ChatTurn]`) a ogni chiamata;
  il fallback funziona anche a metà conversazione.
- Consapevolezza dei token (D13): pre-flight automatico sulla finestra di
  contesto (conteggio esatto on-device da iOS/macOS 26.4, stime oneste per
  i provider cloud) e `contextUsage(instructions:history:)` per decidere
  quando accorciare la storia.
- Primitivo di risoluzione `resolveProvider()` (D9) e provenienza della
  risposta (`respondDetailed` → provider + livello di privacy).
- `MockProvider` pubblico per testare l'integrazione senza rete né device.

### UI opzionale (`AIProviderKitUI`)
- `PrivacyLevelBadge`, `ProviderStatusRow`/`ProviderStatusList`,
  `AIPlaygroundView` (conversazionale, con indicatore di pressione contesto).

### Demo
- macOS: `swift run AIProviderKitDemo`.
- iPhone/iPad: `Examples/iOSDemo/iOSDemo.xcodeproj`.

### Verifica
- 34 test in 7 suite; build verificate su macOS 26.5, simulatore iOS 26.5 e
  iPhone fisico (firma).
