# AIProviderKit — iOS 26 / 26.4 Implementation (internal source)

> Internal documentation of what is **built and shipping** (v1.0.0): the iOS 26
> base tier and the iOS 26.4 token-aware tier. For the iOS 27 design see
> `docs/iOS27-Design.md`. Keep this file in sync with every code change
> (working agreement in CLAUDE.md).

---

## 1. Verified status

Released **v1.0.1** (git tags `1.0.0`, `1.0.1`, 2026-06-12; 1.0.1 translated
all comments, docs, and user-facing strings to English — no behavior change).
`swift build` succeeds and
**34 tests in 7 suites pass** on macOS 26.5 SDK / Xcode 26.6, Swift 6.2 tools.
The iOS demo app builds and runs on the iOS 26.5 simulator (verified on
iPhone 17 Pro) and signs correctly for a physical iPhone 15 Pro Max.

File map:

```
AIProvider/                                (repo root)
├── Package.swift                          // tools 6.2, iOS 26 / macOS 26
├── README.md                              // public guide (GitHub-facing)
├── CHANGELOG.md                           // SemVer release notes
├── CLAUDE.md                              // index + state + roadmap
├── docs/                                  // internal sources (this file & co.)
├── Sources/
│   ├── AIProviderKit/                     // CORE — no UI dependency, ever
│   │   ├── ModelProvider.swift            // protocol + identifiers + statuses + typed errors
│   │   ├── ChatTurn.swift                 // app-supplied conversation turn (D12)
│   │   ├── PrivacyDisclosure.swift        // downgrade event + disclosure policy
│   │   ├── OnDeviceProvider.swift         // wraps SystemLanguageModel, maps GenerationError
│   │   ├── OpenAIProvider.swift           // rewritten ChatGptManager (Codable, typed errors)
│   │   ├── AIOrchestrator.swift           // orchestrator + config + fallback + resolution
│   │   └── Mocks.swift                    // MockProvider (public, for adopters' tests too)
│   ├── AIProviderKitUI/                   // OPTIONAL SwiftUI components (separate product)
│   │   ├── PrivacyLevelBadge.swift        // badge for a PrivacyLevel
│   │   ├── ProviderStatusList.swift       // fallback-chain status list (+ public Row)
│   │   └── AIPlaygroundView.swift         // conversational playground with provenance
│   ├── AIProviderKitDemoUI/               // demo UI shared macOS+iOS (adaptive layout)
│   │   └── DemoRootView.swift             // HSplitView on macOS, TabView on iOS
│   └── AIProviderKitDemo/                 // macOS bootstrap: `swift run AIProviderKitDemo`
│       └── DemoApp.swift
├── Examples/iOSDemo/                      // iPhone/iPad demo app (Xcode project)
│   ├── project.yml                        // XcodeGen spec (carries DEVELOPMENT_TEAM)
│   ├── iOSDemo.xcodeproj
│   └── Sources/iOSDemoApp.swift           // @main wrapper around DemoRootView
└── Tests/AIProviderKitTests/
    └── AIProviderKitTests.swift           // fallback, privacy, history, tokens, parsing
```

## 2. The pieces

- **`ModelProvider`** — the common protocol all providers conform to.
  Provider-agnostic so on-device, dev key, and future PCC/Gemini/Claude all fit.
  Includes the optional token capability (D13), defaulted in a protocol
  extension so custom providers compile without it.
- **`ProviderError`** — typed errors with `isRecoverableByFallback`, the hook the
  fallback logic uses. Recoverable: `.rateLimited`, `.network`,
  `.contextWindowExceeded`, `.unsupportedLanguage`, `.noProviderAvailable`.
  Terminal: `.unauthorized`, `.guardrailViolation`, `.encoding`, `.decoding`,
  `.api`, `.generation`, `.privacyRestricted`, `.cancelled`, `.emptyResponse`.
  **This is the extension point for the iOS 27 quota-driven fallback.**
- **`PrivacyLevel`** — `.external < .appleCloud < .onDevice`, comparable.
- **`PrivacyDisclosure`** — `.silent` / `.notify(handler)` /
  `.askOnPrivacyChange(asyncHandler)` / `.denyDowngrade`. Applied by the
  orchestrator whenever fallback would use a provider *below* the privacy level
  of the chain's first provider (the "baseline"). See D10.
- **`ChatTurn`** — one app-supplied conversation turn (`.user` / `.assistant`),
  the carrier of transcript transparency (D12).
- **`OnDeviceProvider`** — `SystemLanguageModel` + availability handling
  (deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady).
  Maps `LanguageModelSession.GenerationError` cases: context window →
  `.contextWindowExceeded` (recoverable), unsupported language →
  `.unsupportedLanguage` (recoverable), on-device rate limit → `.rateLimited`,
  guardrail → `.guardrailViolation` (terminal, deliberately: we never
  auto-forward content Apple blocked to an external provider).
  History is rebuilt as a native `Transcript` per call
  (`LanguageModelSession(transcript:)`).
- **`OpenAIProvider`** — Codable DTOs, HTTP status → semantic errors
  (429→rateLimited with Retry-After parsing incl. HTTP-date, 401/403→unauthorized,
  `context_length_exceeded` → `.contextWindowExceeded`). Uses
  `max_completion_tokens` (the non-deprecated parameter). History → messages
  array (system → turns → current prompt).
- **`AIOrchestrator`** (actor) — builds the ordered provider list from
  preference; `respond`/`respondDetailed` walk the chain skipping unavailable
  providers, running the token pre-flight (D13), applying the privacy gate,
  falling through on recoverable errors. `resolveProvider()` is the
  *resolution primitive* (D9). `contextUsage()` reports window pressure;
  `providerStatuses()` powers UI. Global access via `configure {}` + `.active`
  (Mutex-protected; Swift 6 forbids bare mutable statics).

### SDK verification notes
1. ✅ `LanguageModelSession(instructions:)` exists — compiles against this SDK.
2. ✅ `LanguageModelSession.GenerationError` cases used and compiling:
   `.exceededContextWindowSize`, `.guardrailViolation`,
   `.unsupportedLanguageOrLocale`, `.rateLimited` (+ `default` for the rest).
3. ✅ `SystemLanguageModel.contextSize` is back-deployed across 26.x;
   `tokenCount(for:)` overloads require 26.4 (checked in the .swiftinterface).
4. On-device generation paths are **not** exercised by unit tests (would need a
   device with Apple Intelligence); use the demo apps for that.

## 3. The two tiers in this codebase

| Behavior | 26.0–26.3 (base) | 26.4+ (token-aware) |
|---|---|---|
| Fallback, privacy disclosure, conversations (D12) | ✅ | ✅ |
| `contextSize` (on-device) | ✅ (back-deployed) | ✅ |
| Exact on-device `tokenCount` | ❌ → `nil` | ✅ |
| Orchestrator pre-flight for on-device | inactive (no counts) | ✅ |
| `contextUsage` with on-device resolved | `nil` | ✅ |
| OpenAI estimates + window table | ✅ | ✅ |

The gate is a single `if #available(iOS 26.4, macOS 26.4, *)` inside
`OnDeviceProvider.tokenCount` — no other code branches on OS version.

## 4. Implemented design decisions (with rationale)

### D4 — Developer key = "AI included in the app's subscription"
The dev key is a business model, not a fallback hack: users with an app
subscription get AI without their own provider account. Key injected at runtime
by the integrating app (Xcode secret), never hardcoded. iOS 26: direct
URLSession call (developer's key in device traffic; consider a proxy at scale).

### D5 — On-device is never assumed present
Requires Apple Intelligence. Detected at runtime; unavailable options are
hidden; never assumed as a guaranteed last resort.

### D7 — Runtime fallback + privacy levels + disclosure
State changes while the user uses the app, so model choice is re-evaluated per
call. Behind the preference is an ordered chain walked at runtime. Crossing the
privacy threshold triggers a configurable disclosure. Only the developer knows
their app's sensitivity, so they choose the policy. (The iOS 27 per-need chain
extends this — see `docs/iOS27-Design.md`.)

### D8 — The orchestrator type is `AIOrchestrator`, not `AIProviderKit`
A type named like its own module shadows the module: `AIProviderKit.Xyz` would
always resolve the type, never the module — a permanent ergonomic tax on every
client. Renamed before anyone adopted the API. The name also says what the
thing is: an orchestrator/resolver, not an agent runtime.

### D9 — Resolution is the primitive; `respond` is the convenience
`respond()` executes; but our core value is *resolution*. So the resolution
primitive is public from day one: `resolveProvider()` returns the chain's first
usable provider without executing anything. On iOS 27 it evolves into
`preferred(_ need:) -> LanguageModel` for Dynamic Profiles — "the primitive
existed all along". `respond`/`respondDetailed` stay as the one-shot
convenience (and `respondDetailed` reports *which* provider answered, at what
privacy level — needed by any honest UI).

### D10 — Privacy disclosure ships in iOS 26, not iOS 27
With `.preferOnDevice`, a transient on-device failure silently re-sends the
user's prompt to OpenAI — a privacy downgrade that happens **today**. So the
disclosure mechanism is live in the base: the baseline is the privacy level of
the chain's *first* provider; before using any provider below it, the
orchestrator applies `PrivacyDisclosure`. Consequence: `.contextWindowExceeded`
and `.unsupportedLanguage` can safely be *recoverable* errors, because the
privacy policy — not the error taxonomy — decides whether crossing to an
external provider is acceptable. Guardrail violations remain terminal by
deliberate choice (never auto-forward content Apple blocked).

### D11 — UI is optional by construction
The core target has zero UI dependencies and is fully configurable headless;
the developer can build any UI on `providerStatuses()` / `respondDetailed()`.
`AIProviderKitUI` is a **separate library product** with drop-in, customizable
SwiftUI components (`PrivacyLevelBadge`, `ProviderStatusRow`/`ProviderStatusList`,
`AIPlaygroundView`). Rows/badges are public so developers can recompose them.
Nothing in the core ever imports SwiftUI.

### D12 — Stateless core, transcript-transparent
The framework **never remembers** conversations, but every call **accepts**
the prior turns as input (`history: [ChatTurn]`, owned and supplied by the
app). Three reasons:
1. **Ownership.** Persistence, editing, trimming, branching of a chat are app
   domain logic. A framework-held session would be an agent runtime,
   and would duplicate Apple's `LanguageModelSession`.
2. **Fallback composability — the key insight.** If conversation state lived
   inside a provider's session, a mid-conversation provider death (PCC quota
   exhausted, on-device rate limit) would trap the transcript in the dead
   provider. With app-supplied history, **every call is self-contained**, so
   any provider in the chain can answer any turn: mid-conversation provider
   switching falls out of the existing per-call fallback for free, privacy
   disclosure included.
3. **Provider mapping is natural.** OpenAI: history → messages array.
   On-device: history → native FoundationModels `Transcript` rebuilt per call.
Known costs, accepted: history is re-sent (and re-prefilled) each turn — no
KV-cache reuse; and long chats hit the small on-device window sooner, which the
architecture absorbs (`.contextWindowExceeded` is recoverable → falls over to a
larger-context provider, privacy policy permitting). When/how to trim or
summarize stays with the developer. `AIPlaygroundView` demonstrates the
pattern: the *view* plays the developer role, holds the exchanges, and passes
them via `history:` on each send.

### D13 — Proactive token awareness as an optional capability
Verified against the real SDK: `SystemLanguageModel.contextSize` is available
on **all of 26.x** (back-deployed), while the five `tokenCount(for:)` overloads
(prompt, instructions, tools, schema, transcript entries) require **26.4**.
Design:
- `ModelProvider` gains an *optional capability* (defaulted in a protocol
  extension): `contextSize: Int?` and
  `tokenCount(prompt:instructions:history:) -> Int?`. `nil` always means
  "don't know" — the framework never guesses.
- On-device: exact counts via the native Transcript entries on 26.4+, `nil` on
  26.0–26.3. OpenAI: known windows per model family (`nil` for unknown models,
  overridable in init) + an ~4 chars/token estimate, deliberately on the low
  side: pre-flight must never wrongly skip a usable provider; real overflow is
  still caught reactively.
- Orchestrator **pre-flight**: if a provider can count and
  `needed + responseTokenReserve >= window`, it's skipped as if it had thrown
  `.contextWindowExceeded` — same recoverable semantics and privacy gating,
  without paying for a doomed generation. Runs *before* the privacy gate (never
  ask the user about a provider that can't serve the call). The reserve is
  `config.maxTokens` (or explicit in `init(providers:)`).
- `contextUsage(instructions:history:)` reports the conversation's pressure on
  the *resolved* provider's window. The app decides when to trim/summarize —
  same division of labor as D10/D12: we detect, the developer decides.
- This capability surface is where iOS 27's per-model token reading will land.

## 5. Public API that must stay stable

```swift
// configuration
AIOrchestrator.configure { (config: inout AIConfiguration) in ... }
AIOrchestrator(configuration: AIConfiguration)      // explicit, no global state
AIOrchestrator(providers: [any ModelProvider],      // tests / custom providers
               privacyDisclosure: PrivacyDisclosure,
               responseTokenReserve: Int)
AIOrchestrator.active                               // configured shared instance

// usage — history is app-owned conversation context (D12), defaults to []
try await kit.respond(to: prompt, instructions: nil, history: []) -> String
try await kit.respondDetailed(to:instructions:history:) -> AIResponse  // + provenance
try await kit.resolveProvider() -> any ModelProvider            // the primitive (D9)
await kit.contextUsage(instructions:history:) -> ContextUsage?  // window pressure (D13)
await kit.availableProviders() -> [ProviderIdentifier]
await kit.providerStatuses() -> [ProviderStatus]                // for UI

// extension points
protocol ModelProvider { identifier; privacyLevel; availability(); respond(to:instructions:history:);
                         contextSize; tokenCount(prompt:instructions:history:) }  // last two defaulted (D13)
enum ProviderError { ...; var isRecoverableByFallback: Bool }
enum PrivacyLevel { external < appleCloud < onDevice }
enum PrivacyDisclosure { silent, notify(…), askOnPrivacyChange(…), denyDowngrade }
struct PrivacyDowngrade { from, to, provider }
enum ModelPreference { preferOnDevice, preferDeveloperKey, onDeviceOnly, developerKeyOnly }
struct ChatTurn { role (.user/.assistant), text }               // app-supplied turn (D12)
struct AIResponse { text, provider, privacyLevel }
struct ProviderStatus { identifier, privacyLevel, availability, contextSize }
struct ContextUsage { tokens, contextSize, provider, fraction } // (D13)
```

Adding iOS 27 providers/quota/Dynamic-Profiles bridge must extend these, not
break them (SemVer: iOS 27 stays in 1.x). `AIProviderKitUI` components are
additive and optional by definition.

## 6. Demo & verification

- `swift build` — builds core + UI + demo (macOS side).
- `swift test` — 34 tests: fallback chain, terminal vs recoverable errors,
  privacy disclosure policies (all four), resolution primitive, provider
  statuses, conversation-history pass-through incl. across fallback (D12),
  token pre-flight incl. response reserve and the no-capability case (D13),
  context-usage reporting, OpenAI window table + estimate,
  global configure, Retry-After parsing.
- `swift run AIProviderKitDemo` — macOS test UI.
- **iOS demo:** open `Examples/iOSDemo/iOSDemo.xcodeproj` and run on an
  iPhone/iPad (or simulator with an iOS 26 runtime — Xcode 26.6 ships iPhone 17
  family simulators). The project was generated with XcodeGen from
  `project.yml`; it's committed, so regenerate (`xcodegen generate`) only after
  editing the spec. The development team is set in `project.yml`
  (`DEVELOPMENT_TEAM`), so it survives regeneration — don't set it only in
  Xcode's Signing pane, that edit lives in the generated pbxproj.

Both demos render the same `DemoRootView` (target `AIProviderKitDemoUI`):
configure providers/key/preference live, see the fallback chain status with
real availability reasons, send prompts, see which provider answered with its
privacy badge, and watch privacy-downgrade notifications. Layout is adaptive —
split view on macOS, tabs (Configure / Playground) on iOS. The playground is a
real conversation (D12): follow-ups work because the view holds the history and
passes it per call; "New conversation" resets it. It also shows the context
pressure ("context N% of \<window\>", orange above 80%) for the provider that
would answer next, and the status list shows each provider's window size. On
26.0–26.3 the on-device pressure indicator simply doesn't appear (no counting
API): that's the base tier behaving as designed.

Model-limitation behavior to expect:
- Simulator / non-Apple-Intelligence device: on-device row shows the reason
  (e.g. "Apple Intelligence is not enabled in Settings") and the chain
  falls back to the developer key if configured — with the privacy-downgrade
  notification visible in the Privacy section.
- iPhone 15 Pro / 16+ with Apple Intelligence on: on-device row is green and
  answers carry the "On device" badge.
- Context-window overflow / unsupported language on-device fall through to the
  cloud provider per D10; guardrail violations surface as errors (terminal).

**Device-install troubleshooting (learned June 2026):** Xcode's
"Install Application not available (DVTCoreDevice code 4)" can mean the
*phone* doesn't expose the `com.apple.coredevice.feature.installapp`
capability — i.e. app installation is blocked on the device (typically
Screen Time → Content & Privacy Restrictions → Installing Apps = Don't Allow,
or an MDM profile), even with Developer Mode on and pairing fine. Diagnose with
`xcrun devicectl device install app --device <id> <app>` (real error) and
`xcrun devicectl device info details --device <id>` (capability list,
developerModeStatus).

## 7. Origin

Started from a primitive `ChatGptManager` (single OpenAI REST class returning
`String?`). Its best ideas — the repository protocol and the mock — were
generalized into `ModelProvider` and `MockProvider`. The rest was rebuilt
around typed errors, config, the orchestrator, and (June 2026) the resolution
primitive, privacy disclosure, transcript transparency, and token awareness.
