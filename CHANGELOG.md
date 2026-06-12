# Changelog

All notable changes to this package. Versioning: [SemVer](https://semver.org).
Stability promise (see docs, D3): the iOS 27 extensions will be additive on
the same API — they stay within the current major series.

## [2.0.0] — 2026-06-12

- **Renamed the package from AIProviderKit to VoltaSDK** (**VOLTA** =
  *Versatile Orchestration Layer for Tiered AI*). Products and modules:
  `AIProviderKit` → `VoltaSDK`, `AIProviderKitUI` → `VoltaSDKUI`. Major bump
  because module names are part of the API (`import VoltaSDK`); there are no
  functional changes — the feature set is exactly 1.0.1's.
- Migration: update the package dependency and the `import` statements; all
  type names (`AIOrchestrator`, `ChatTurn`, `ProviderError`, …) are unchanged.

## [1.0.1] — 2026-06-12

- All code comments, documentation, and user-facing strings (availability
  reasons, error descriptions, UI labels, demo) translated from Italian to
  English. No behavioral changes; API unchanged.

## [1.0.0] — 2026-06-12

First release. iOS 26 / macOS 26 base, Swift 6.2.

### Core (`AIProviderKit`)
- `AIOrchestrator`: runtime fallback chain across providers, with typed
  errors (`ProviderError`) and the recoverable/terminal distinction.
- Bundled providers: `OnDeviceProvider` (Foundation Models, Apple
  Intelligence) and `OpenAIProvider` (developer key, Chat Completions).
- Privacy-downgrade disclosure (`PrivacyDisclosure`):
  `.silent` / `.notify` / `.askOnPrivacyChange` / `.denyDowngrade` (D10).
- Transcript-transparent multi-turn conversations (D12): the core is
  stateless, the app passes the history (`history: [ChatTurn]`) on every
  call; fallback works mid-conversation.
- Token awareness (D13): automatic context-window pre-flight (exact
  on-device counting from iOS/macOS 26.4, honest estimates for cloud
  providers) and `contextUsage(instructions:history:)` to decide when to
  trim the history.
- Resolution primitive `resolveProvider()` (D9) and response provenance
  (`respondDetailed` → provider + privacy level).
- Public `MockProvider` for testing integrations without network or device.

### Optional UI (`AIProviderKitUI`)
- `PrivacyLevelBadge`, `ProviderStatusRow`/`ProviderStatusList`,
  `AIPlaygroundView` (conversational, with a context-pressure indicator).

### Demos
- macOS: `swift run AIProviderKitDemo`.
- iPhone/iPad: `Examples/iOSDemo/iOSDemo.xcodeproj`.

### Verification
- 34 tests in 7 suites; builds verified on macOS 26.5, the iOS 26.5
  simulator, and a physical iPhone (signing).
