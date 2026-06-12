# AIProviderKit — Project Context

> This file is the single source of truth for the project. It captures every
> design decision, the reasoning behind it, the current state of the code, and
> the roadmap. Read it fully before making changes.
> **Working agreement: every code change must update this file in the same
> session** — status, decisions, and roadmap must always reflect reality.
> (Language note: written in English for Claude Code; the codebase comments and
> the companion spec are in Italian. Ask if you want this translated.)

---

## 1. TL;DR — what this is

AIProviderKit is a Swift Package that **resolves which AI model to use** at runtime
and hands a ready model to the app, with automatic fallback and privacy
disclosure. It does **not** invent its own agent abstraction — on iOS 27 it
*feeds* Apple's native Dynamic Profiles rather than wrapping them.

The project ships in **two phases**:

- **iOS 26 base (built, compiles, tests green):** two providers — on-device
  (Foundation Models) and a developer key (OpenAI via REST) — with runtime
  fallback, privacy-downgrade disclosure, and a stable public API. Optional
  SwiftUI components and demo apps for both macOS and iPhone/iPad.
- **iOS 27 extension (designed, not built):** multi-provider via the public
  `LanguageModel` protocol, Private Cloud Compute, user accounts (Gemini/Claude),
  a per-need fallback chain with quota handling, and Dynamic Profiles.

The public API (`configure`, `respond`, `resolveProvider`) is designed to stay
**identical** across both phases, so adopting the iOS 26 base never forces an
app rewrite later. **We only require the package to build for iOS 26**; iOS 27
shapes decisions but never blocks compilation.

---

## 2. Current status — what's built (verified June 2026)

Working Swift Package: `swift build` succeeds and **23 tests in 5 suites pass**
on macOS 26.5 SDK / Xcode 26.6, Swift 6.2 tools. The iOS demo app builds and
runs on the iOS 26.5 simulator (verified on iPhone 17 Pro: the fallback chain
correctly reports on-device as unavailable with the Apple Intelligence reason).
File map:

```
AIProvider/                                (repo root)
├── Package.swift                          // tools 6.2, iOS 26 / macOS 26
├── README.md
├── CLAUDE.md                              // this file
├── Sources/
│   ├── AIProviderKit/                     // CORE — no UI dependency, ever
│   │   ├── ModelProvider.swift            // protocol + identifiers + statuses + typed errors
│   │   ├── PrivacyDisclosure.swift        // downgrade event + disclosure policy
│   │   ├── OnDeviceProvider.swift         // wraps SystemLanguageModel, maps GenerationError
│   │   ├── OpenAIProvider.swift           // rewritten ChatGptManager (Codable, typed errors)
│   │   ├── AIOrchestrator.swift           // orchestrator + config + fallback + resolution
│   │   └── Mocks.swift                    // MockProvider for tests
│   ├── AIProviderKitUI/                   // OPTIONAL SwiftUI components (separate product)
│   │   ├── PrivacyLevelBadge.swift        // badge for a PrivacyLevel
│   │   ├── ProviderStatusList.swift       // fallback-chain status list (+ public Row)
│   │   └── AIPlaygroundView.swift         // drop-in prompt→response view with provenance
│   ├── AIProviderKitDemoUI/               // demo UI shared macOS+iOS (adaptive layout)
│   │   └── DemoRootView.swift             // HSplitView on macOS, TabView on iOS
│   └── AIProviderKitDemo/                 // macOS bootstrap: `swift run AIProviderKitDemo`
│       └── DemoApp.swift
├── Examples/iOSDemo/                      // iPhone/iPad demo app (Xcode project)
│   ├── project.yml                        // XcodeGen spec (project is committed; regen optional)
│   ├── iOSDemo.xcodeproj
│   └── Sources/iOSDemoApp.swift           // @main wrapper around DemoRootView
└── Tests/AIProviderKitTests/
    └── AIProviderKitTests.swift           // fallback, privacy, resolution, parsing
```

What each core piece does:

- **`ModelProvider`** — the common protocol all providers conform to.
  Provider-agnostic so on-device, dev key, and future PCC/Gemini/Claude all fit.
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
  of the chain's first provider (the "baseline"). Already live on iOS 26 (see D10).
- **`OnDeviceProvider`** — `SystemLanguageModel` + availability handling
  (deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady).
  Maps `LanguageModelSession.GenerationError` cases: context window →
  `.contextWindowExceeded` (recoverable), unsupported language →
  `.unsupportedLanguage` (recoverable), on-device rate limit → `.rateLimited`,
  guardrail → `.guardrailViolation` (terminal, deliberately: we never
  auto-forward content Apple blocked to an external provider).
- **`OpenAIProvider`** — Codable DTOs, HTTP status → semantic errors
  (429→rateLimited with Retry-After parsing incl. HTTP-date, 401/403→unauthorized,
  `context_length_exceeded` → `.contextWindowExceeded`). Uses
  `max_completion_tokens` (the non-deprecated parameter).
- **`AIOrchestrator`** (actor) — builds the ordered provider list from
  preference; `respond`/`respondDetailed` walk the chain skipping unavailable
  providers, applying the privacy gate, falling through on recoverable errors.
  `resolveProvider()` is the *resolution primitive* (see D9).
  `providerStatuses()` powers UI. Global access via `configure {}` + `.active`
  (Mutex-protected; Swift 6 forbids bare mutable statics).

### SDK verification notes (was "two things to verify")
1. ✅ `LanguageModelSession(instructions:)` exists — compiles against this SDK.
2. ✅ `LanguageModelSession.GenerationError` cases used and compiling:
   `.exceededContextWindowSize`, `.guardrailViolation`,
   `.unsupportedLanguageOrLocale`, `.rateLimited` (+ `default` for the rest).
3. On-device generation paths are **not** exercised by unit tests (would need a
   device with Apple Intelligence); use the demo app for that.

---

## 3. Core design decisions (with rationale)

These are the conclusions from the brainstorm + the June 2026 architecture
review. The *why* matters as much as the *what*.

### D1 — Feed Dynamic Profiles, don't abstract them
Apple's Dynamic Profiles (iOS 27) are already a clean, SwiftUI-style declarative API
for agents. Building a parallel declarative layer on top would fight the framework
and always be less expressive. **Our value is model resolution**, which Apple does
*not* provide: given user choice + auth + quota + device support, return the
concrete `LanguageModel`. The developer writes Dynamic Profiles natively and
writes e.g. `.model(orchestrator.preferred(.reasoning))`.

### D2 — No custom `Agent` class
Rejected an `Agent(id:instructions:tools:)` abstraction: it would become a weak
duplicate of Dynamic Profiles carried for years for back-compat. The framework
never owns the concept of "agent" — it only owns model resolution.

### D3 — iOS 26 base + iOS 27 extension, one stable API
Ship value now on iOS 26 while designing the public surface to be exactly what
iOS 27 needs. iOS 27 features light up when available; absent silently on iOS 26.
No app rewrite on upgrade. Build target is iOS 26 only.

### D4 — Developer key = "AI included in the app's subscription"
The dev key is a business model, not a fallback hack: users with an app
subscription get AI without their own provider account. Key injected at runtime
by the integrating app (Xcode secret), never hardcoded.
- iOS 26: direct URLSession call (developer's key in device traffic; consider a
  proxy at scale). iOS 27: a provider conforming to `LanguageModel`.

### D5 — On-device is never assumed present
Requires Apple Intelligence. Detected at runtime; unavailable options are
hidden; never assumed as a guaranteed last resort.

### D6 — PCC is the "free powered" tier (iOS 27)
No auth, no key, per-user **daily quota** (higher with iCloud+), free for apps
<2M downloads. **PCC quota can run out mid-use** — the main reason fallback must
be automatic and runtime, not a static setup choice.

### D7 — Runtime fallback + privacy levels + disclosure
State changes while the user uses the app, so model choice is re-evaluated per
call. Developer expresses a *need* (`.lightweight`/`.reasoning`/`.largeContext`
on iOS 27); behind it an ordered chain walked at runtime. Crossing the privacy
threshold triggers a configurable disclosure. Only the developer knows their
app's sensitivity, so they choose the policy.

### D8 — The orchestrator type is `AIOrchestrator`, not `AIProviderKit` *(June 2026)*
A type named like its own module shadows the module: `AIProviderKit.Xyz` would
always resolve the type, never the module — a permanent ergonomic tax on every
client. Renamed before anyone adopts the API. The name also says what the thing
is: an orchestrator/resolver, not an agent runtime.

### D9 — Resolution is the primitive; `respond` is the convenience *(June 2026)*
`respond()` executes; but per D1/D2 our core value is *resolution*. So the
resolution primitive is public from day one: `resolveProvider()` returns the
chain's first usable provider without executing anything. On iOS 27 it evolves
into `preferred(_ need:) -> LanguageModel` for Dynamic Profiles — "the primitive
existed all along", not "we migrated from a wrapper to a resolver". `respond` /
`respondDetailed` stay as the one-shot convenience (and `respondDetailed`
reports *which* provider answered, at what privacy level — needed by any honest UI).

### D10 — Privacy disclosure ships in iOS 26, not iOS 27 *(June 2026)*
With `.preferOnDevice`, a transient on-device failure silently re-sends the
user's prompt to OpenAI — a privacy downgrade that happens **today**. So the
disclosure mechanism is live in the base: the baseline is the privacy level of
the chain's *first* provider; before using any provider below it, the
orchestrator applies `PrivacyDisclosure`. Consequence: `.contextWindowExceeded`
and `.unsupportedLanguage` can safely be *recoverable* errors, because the
privacy policy — not the error taxonomy — decides whether crossing to an
external provider is acceptable. Guardrail violations remain terminal by
deliberate choice (never auto-forward content Apple blocked).

### D11 — UI is optional by construction *(June 2026)*
The core target has zero UI dependencies and is fully configurable headless;
the developer can build any UI on `providerStatuses()` / `respondDetailed()`.
`AIProviderKitUI` is a **separate library product** with drop-in, customizable
SwiftUI components (`PrivacyLevelBadge`, `ProviderStatusRow`/`ProviderStatusList`,
`AIPlaygroundView`). Rows/badges are public so developers can recompose them.
Nothing in the core ever imports SwiftUI.

---

## 4. iOS 26 vs iOS 27 capability split

**Available in iOS 26 (base is built on this):**
- `SystemLanguageModel`, `LanguageModelSession`, `respond`, `streamResponse`
- Guided generation (`@Generable`, `@Guide`), tool calling
- Availability API (`SystemLanguageModel.default.availability`)
- LoRA adapters
- iOS 26.4: context-size inspection + token counting APIs

**Exclusive to iOS 27 (extension targets these):**
- Public `LanguageModel` protocol → multi-provider (Gemini, Claude, OpenAI)
- `PrivateCloudComputeLanguageModel` → PCC
- Dynamic Profiles → declarative agents/subagents
- Foundation Models framework **Utilities** (open-source): Skills, Profile
  Modifiers, a Chat Completions `LanguageModel`
- Vision input on the on-device model
- System tools: OCRTool, BarcodeReaderTool, Spotlight RAG

---

## 5. Provider reference

| Provider | Auth | Cost | Privacy | Requirement | Phase |
|---|---|---|---|---|---|
| On-device (~3B) | none | free | max (offline) | Apple Intelligence | iOS 26 |
| Developer Key (OpenAI) | dev key | dev pays | external | key configured | iOS 26 |
| Private Cloud Compute | none | free w/ daily quota | high (no storage) | Apple Intelligence + app <2M dl | iOS 27 |
| Google Gemini | OAuth (Firebase) | user tokens | provider-dependent | user account | iOS 27 |
| Anthropic Claude | user API key | user tokens | provider-dependent | user account | iOS 27 |
| OpenAI ChatGPT | user API key | user tokens | provider-dependent | user account | iOS 27 |

---

## 6. Roadmap / next steps (ordered)

1. ~~Compile & green the tests~~ ✅ done (June 2026): builds with tools 6.2,
   23 tests green; SDK-name caveats resolved.
2. ~~Privacy disclosure mechanism~~ ✅ shipped in the iOS 26 base (D10).
3. **Streaming.** Add `streamResponse` to `ModelProvider` and both providers
   (OpenAI via SSE `"stream": true`). Resolves the streaming asymmetry between
   on-device and dev key. Design question: how does a stream interact with
   fallback (fail before first token = fall through; fail mid-stream = surface)?
4. **Token/context awareness** (iOS 26.4 APIs): surface context-window pressure
   and a summarize-or-truncate hook before saturation.
5. **Multi-turn sessions.** Currently a session is created per call; design
   persistent session handling and how it interacts with fallback (open Q6).
   `AIPlaygroundView`'s visual history is NOT real multi-turn — each send is
   independent.
6. **iOS 27 providers:** `PrivateCloudComputeProvider`, then user-account
   Gemini/Claude via the `LanguageModel` protocol; wire into the ordered list.
7. **Runtime fallback chain keyed on need** (`.lightweight/.reasoning/.largeContext`):
   replaces/extends `ModelPreference` (which deliberately stays at 4 cases — a
   third provider makes a closed enum combinatorial; see review notes).
8. **`preferred(_ need:)` bridge** for Dynamic Profiles, evolving
   `resolveProvider()` (D9).
9. **Model picker component** in AIProviderKitUI (meaningful once >1
   user-visible option; `ProviderStatusList` is the embryo).

---

## 7. Open questions (raised for the WWDC Group Labs)

High priority — they unblock the fallback architecture:
- **Q1:** Is PCC remaining quota readable *before* a call (proactive), or only via an
  error at call time (reactive)? Determines the whole selection strategy.
- **Q2:** What error does `PrivateCloudComputeLanguageModel` throw on quota exhaustion?
  Is it a distinct type (vs network/server-busy) so fallback only fires in the right case?
- **Q3:** When does the daily PCC quota reset — local midnight, UTC, or rolling 24h?
- **Q4:** How to distinguish "this user is out of quota" from "PCC temporarily down"?

Composition / sessions:
- **Q5:** Can a runtime-chosen `LanguageModel` be passed to `.model(...)` inside a Dynamic
  Profile, or is a Profile's model fixed once declared?
- **Q6:** If PCC quota runs out mid-conversation, can the same session continue on another
  model preserving the transcript, or must it be recreated? (Critical for multi-turn.)
- **Q7:** Is the transcript/KV-cache portable across different models (PCC → on-device)?

Providers / Utilities / capabilities:
- **Q8:** Utilities' Chat Completions `LanguageModel` — point at any compatible endpoint
  with URL+key? What does it expose, especially token counts?
- **Q9:** Minimum requirements to conform a custom provider to `LanguageModel`
  (streaming / tool calling mandatory or optional)?
- **Q10:** Uniform token-usage reading across models, or per-implementation?
- **Q11:** Official runtime availability API for on-device + reasons.
- **Q12:** Feature parity (Generable, tool calling, reasoningLevel) across models — risk of
  losing structured output on fallback?
- **Q13:** Token cost predictability with guided generation.

Distribution:
- **Q14:** PCC entitlement + application process/timeline; test environment before approval?
- **Q15:** PCC behavior in TestFlight / debug; different quotas in dev vs prod?
- **Q16:** Regional restrictions (EU/China) the framework must treat as "unavailable"?

General validation:
- **Q17:** "I'm building a layer that gives an orchestrator to Dynamic Profiles, resolving
  at runtime which LanguageModel to use based on user choice, auth, quota and availability,
  with automatic fallback down to on-device. Any pitfalls or edge cases I'm missing?"

---

## 8. Public API that must stay stable

```swift
// configuration
AIOrchestrator.configure { (config: inout AIConfiguration) in ... }
AIOrchestrator(configuration: AIConfiguration)      // explicit, no global state
AIOrchestrator(providers: [any ModelProvider],      // tests / custom providers
               privacyDisclosure: PrivacyDisclosure)
AIOrchestrator.active                               // configured shared instance

// usage
try await kit.respond(to: prompt, instructions: nil) -> String
try await kit.respondDetailed(to:instructions:) -> AIResponse   // + provenance
try await kit.resolveProvider() -> any ModelProvider            // the primitive (D9)
await kit.availableProviders() -> [ProviderIdentifier]
await kit.providerStatuses() -> [ProviderStatus]                // for UI

// extension points
protocol ModelProvider { identifier; privacyLevel; availability(); respond(to:instructions:) }
enum ProviderError { ...; var isRecoverableByFallback: Bool }
enum PrivacyLevel { external < appleCloud < onDevice }
enum PrivacyDisclosure { silent, notify(…), askOnPrivacyChange(…), denyDowngrade }
struct PrivacyDowngrade { from, to, provider }
enum ModelPreference { preferOnDevice, preferDeveloperKey, onDeviceOnly, developerKeyOnly }
struct AIResponse { text, provider, privacyLevel }
struct ProviderStatus { identifier, privacyLevel, availability }
```

Adding iOS 27 providers/quota/Dynamic-Profiles bridge must extend these, not
break them. `AIProviderKitUI` components (PrivacyLevelBadge, ProviderStatusRow,
ProviderStatusList, AIPlaygroundView) are additive and optional by definition.

---

## 9. Demo & verification

- `swift build` — builds core + UI + demo (macOS side).
- `swift test` — 23 tests: fallback chain, terminal vs recoverable errors,
  privacy disclosure policies (all four), resolution primitive, provider
  statuses, global configure, Retry-After parsing.
- `swift run AIProviderKitDemo` — macOS test UI.
- **iOS demo:** open `Examples/iOSDemo/iOSDemo.xcodeproj` and run on an
  iPhone/iPad (or simulator with an iOS 26 runtime — Xcode 26.6 ships iPhone 17
  family simulators). The project was generated with XcodeGen from
  `project.yml`; it's committed, so regenerate (`xcodegen generate`) only after
  editing the spec. To run on a physical iPhone set your development team in
  Signing & Capabilities.

Both demos render the same `DemoRootView` (target `AIProviderKitDemoUI`):
configure providers/key/preference live, see the fallback chain status with
real availability reasons, send prompts, see which provider answered with its
privacy badge, and watch privacy-downgrade notifications. Layout is adaptive —
split view on macOS, tabs (Configura / Playground) on iOS.

Model-limitation behavior to expect:
- Simulator / non-Apple-Intelligence device: on-device row shows the reason
  (e.g. "Apple Intelligence non è attivo nelle Impostazioni") and the chain
  falls back to the developer key if configured — with the privacy-downgrade
  notification visible in the Privacy section.
- iPhone 15 Pro / 16+ with Apple Intelligence on: on-device row is green and
  answers carry the "Sul dispositivo" badge.
- Context-window overflow / unsupported language on-device fall through to the
  cloud provider per D10; guardrail violations surface as errors (terminal).

---

## 10. Origin

Started from a primitive `ChatGptManager` (single OpenAI REST class returning
`String?`). Its best ideas — the repository protocol and the mock — were
generalized into `ModelProvider` and `MockProvider`. The rest was rebuilt around
typed errors, config, the orchestrator, and (June 2026) the resolution
primitive + privacy disclosure.
