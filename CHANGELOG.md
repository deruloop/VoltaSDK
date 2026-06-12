# Changelog

All notable changes to this package. Versioning: [SemVer](https://semver.org).
**Pre-1.0 policy:** VoltaSDK is in active development — 0.x minor versions may
evolve the API. **1.0.0 will mark the complete feature set**, including the
iOS 27 extension (multi-provider, PCC, Dynamic Profiles bridge).

## [0.3.2] — 2026-06-13

- **`ModelSelector` no longer lets a configuration look like a user
  activation (gate invariant):** nothing is ever committed without passing
  through `onSelection`, including the initial state. With a nil
  `selection` binding the selector auto-selects the on-device model iff
  available — the only gate-free provider — running even that through the
  handler; cloud providers are **never preselected**. Fixes the state where
  a developer-key-first configuration appeared "already active" without the
  entitlement gate ever firing. A non-nil initial binding (persisted user
  choice) is never overridden.
- Demo: the chat is disabled until a model is committed, demonstrating the
  `selection == nil` ("no model committed") contract that keeps gated
  providers from answering before activation.

## [0.3.1] — 2026-06-12

- Documentation text adjustments only; no code changes.

## [0.3.0] — 2026-06-12

- **`ModelSelector` redesigned as a collapsed disclosure:** resting state is
  a single row with the active choice; tapping expands the options. Scales
  to the longer iOS 27 provider list.
- **Selection is now a three-way response** (`ModelSelectionResponse`):
  `.activate`, `.deny(message:)`, or `.deferred` — the app takes over with
  its own view (paywall, settings, future OAuth page) and commits later by
  setting the `selection` binding. Replaces the boolean `activation:` hook.
- Default labels no longer claim "included with your subscription" — the
  component makes no business assumptions; brand rows via `labels:`.
- Demo: the developer-model field now appears as a consequence of entering
  a key (scoped to the detected vendor, with that vendor's catalog link);
  the cloud-model selection demonstrates the `.deferred` path with a
  paywall sheet that commits externally.
- Migration from 0.2.0: replace `activation: { … true/false }` with
  `onSelection: { … .activate / .deny() }`; `showsActiveBadge` was removed
  (the collapsed row itself is the confirmation).

## [0.2.0] — 2026-06-12

- **Multi-vendor developer key (D15):** the `developerKey` slot now accepts
  OpenAI, Anthropic (Claude), or Google (Gemini) keys. The vendor is
  auto-detected from the key format (`sk-ant-…`/`AIza…`/`sk-…`), overridable
  via `developerKeyVendor`. New `AnthropicProvider` and `GeminiProvider`
  with the same typed errors, history mapping (D12), and token awareness
  (D13) as the OpenAI provider.
- `developerKeyModel` is now optional (`nil` = the vendor's default model)
  and no longer pre-filled in the demo: the model name belongs to the key's
  vendor. `CloudVendor.modelDocumentationURL` links to each vendor's model
  catalog; the demo surfaces detection and the links.
- Demo: keyboard now dismisses interactively by scrolling everywhere.
- Migration from 0.1.0: if you set `developerKeyModel`, the type changed
  from `String` to `String?` — existing assignments keep compiling; only
  reads need unwrapping.

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
