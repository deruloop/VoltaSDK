# Changelog

All notable changes to this package. Versioning: [SemVer](https://semver.org).
**Pre-1.0 policy:** VoltaSDK is in active development — 0.x minor versions may
evolve the API. **1.0.0 will mark the complete feature set**, including the
iOS 27 extension (multi-provider, PCC, Dynamic Profiles bridge).

## [0.1.0] — 2026-06-12

Initial development release: the full iOS 26 / macOS 26 base, Swift 6.2.
(Consolidates the earlier internal iterations, including the rename from the
AIProviderKit working title to **VoltaSDK** — *Versatile Orchestration Layer
for Tiered AI* — and the full English translation.)

### Core (`VoltaSDK`)
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

### Optional UI (`VoltaSDKUI`)
- `ModelSelector`: drop-in **user-side** model picker with an "active"
  confirmation badge and a developer `activation` gate (paywall /
  entitlement checks today; OAuth flows for iOS 27 user-account providers
  through the same hook). Customizable labels, flags, and a public row.
- `PrivacyLevelBadge`, `ProviderStatusRow`/`ProviderStatusList`,
  `AIPlaygroundView` (conversational, with a context-pressure indicator).

### Demos
- macOS (`swift run VoltaSDKDemo`) and iPhone/iPad
  (`Examples/iOSDemo/iOSDemo.xcodeproj`), sharing one adaptive UI split into
  a Developer side (configuration) and a User side (chat + `ModelSelector`).

### Verification
- 34 tests in 7 suites; builds verified on macOS 26.5, the iOS 26.5
  simulator, and a physical iPhone (signing).
