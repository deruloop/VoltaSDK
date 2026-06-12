# VoltaSDK — iOS 27 Design (internal source)

> Internal documentation of the **iOS 27 extension: designed, NOT implemented**.
> No iOS 27 code exists in the package (and none can compile until the iOS 27
> SDK ships). This file holds everything we know and have decided; the open
> questions that still gate implementation live in
> `docs/iOS27-OpenQuestions.md` and will be merged back here once answered.
> The shipped iOS 26/26.4 implementation is documented in
> `docs/iOS26-Implementation.md`.

---

## 1. The plan in one paragraph

On iOS 27 Apple opens the Foundation Models stack: a public `LanguageModel`
protocol (multi-provider), `PrivateCloudComputeLanguageModel` (PCC), and
Dynamic Profiles (declarative agents). VoltaSDK's job stays the same —
**model resolution** — but the chain grows: on-device, PCC, developer key, and
user-account providers (Gemini/Claude), selected per call by need, auth, quota,
availability, and privacy policy. The public API does not change: iOS 27
features are additive (SemVer: within the current major, 2.x).

## 2. Founding decisions

### D1 — Feed Dynamic Profiles, don't abstract them
Apple's Dynamic Profiles (iOS 27) are already a clean, SwiftUI-style declarative
API for agents (`struct …: LanguageModelSession.DynamicProfile` with a `body`
and result builder, using `.model(...)`, `.temperature(...)`,
`.reasoningLevel(...)`). Building a parallel declarative layer on top would
fight the framework and always be less expressive. **Our value is model
resolution**, which Apple does *not* provide: given user choice + auth + quota
+ device support, return the concrete `LanguageModel`. The developer writes
Dynamic Profiles natively and writes e.g.
`.model(orchestrator.preferred(.reasoning))`.

### D2 — No custom `Agent` class
Rejected an `Agent(id:instructions:tools:)` abstraction: it would become a weak
duplicate of Dynamic Profiles carried for years for back-compat. The framework
never owns the concept of "agent" — it only owns model resolution.

### D3 — iOS 26 base + iOS 27 extension, one stable API
Ship value now on iOS 26 while designing the public surface to be exactly what
iOS 27 needs. iOS 27 features light up when available; absent silently on
iOS 26. No app rewrite on upgrade. Build target is iOS 26 only until the iOS 27
SDK is adopted.

### D6 — PCC is the "free powered" tier
Private Cloud Compute: a large server model that integrates like on-device —
**no auth, no API key**, built into the OS with iCloud. Free for the developer
(apps <2M downloads, apply on the developer website). Per-user **daily quota**,
higher with iCloud+. Crucial implication: **PCC quota can run out mid-use at
runtime** — the main reason the fallback must be automatic and runtime, not a
static setup choice.

### D7 (iOS 27 part) — Per-need chains + disclosure
The developer expresses a *need* (`.lightweight` / `.reasoning` /
`.largeContext`); behind it is an ordered fallback chain the framework walks at
runtime, scaling automatically on recoverable failure (quota, network, auth
expiry). Each model has a privacy rating; crossing the privacy threshold
(e.g. PCC → external provider) triggers the disclosure policy — already shipped
in iOS 26 (see D10 in the iOS 26 doc), so on iOS 27 it only gains the
`.appleCloud` level in practice.

### D14 — One package, three capability tiers — not three SDKs
- **Tier 26.0 (base):** fallback + privacy + transcript transparency; context
  handling reactive only.
- **Tier 26.4 (token-aware):** exact on-device counting, proactive pre-flight,
  `contextUsage` — gated by `if #available(iOS 26.4, *)` *inside* the
  on-device provider.
- **Tier 27 (multi-provider):** new capabilities arrive as **whole new types**
  (PCC provider, user-account providers, `preferred(_:)` bridge), each marked
  `@available(iOS 27, *)` at the type level and wired into `buildProviders`
  in one place — not `if` statements scattered through shared logic.
Rationale: small in-API deltas suit *expression-level* availability checks;
paradigm-sized deltas suit *type-level* gating, because the orchestration logic
doesn't branch — the provider list just gets longer on newer OSes. Three
separate branches/packages were rejected: combinatorial maintenance, and D3
already promises adopters one stable API where features light up.
Practical constraint: iOS 27 code physically requires the iOS 27 SDK
(Xcode beta) to compile — until then, iOS 27 remains design-only.

## 3. iOS 26 vs iOS 27 capability split

**Available in iOS 26 (base is built on this):**
- `SystemLanguageModel`, `LanguageModelSession`, `respond`, `streamResponse`
- Guided generation (`@Generable`, `@Guide`), tool calling
- Availability API (`SystemLanguageModel.default.availability`)
- LoRA adapters
- iOS 26.4: context-size inspection + token counting APIs (shipped, D13)

**Exclusive to iOS 27 (this design targets these):**
- Public `LanguageModel` protocol → multi-provider (Gemini, Claude, OpenAI)
- `PrivateCloudComputeLanguageModel` → PCC
- Dynamic Profiles → declarative agents/subagents
- Foundation Models framework **Utilities** (open-source): Skills, Profile
  Modifiers, a Chat Completions `LanguageModel`
- Vision input on the on-device model
- System tools: OCRTool, BarcodeReaderTool, Spotlight RAG

## 4. Provider reference (target state)

| Provider | Auth | Cost | Privacy | Requirement | Phase |
|---|---|---|---|---|---|
| On-device (~3B) | none | free | max (offline) | Apple Intelligence | iOS 26 ✅ |
| Developer Key (OpenAI) | dev key | dev pays | external | key configured | iOS 26 ✅ |
| Private Cloud Compute | none | free w/ daily quota | high (no storage) | Apple Intelligence + app <2M dl | iOS 27 |
| Google Gemini | OAuth (Firebase) | user tokens | provider-dependent | user account | iOS 27 |
| Anthropic Claude | user API key | user tokens | provider-dependent | user account | iOS 27 |
| OpenAI ChatGPT | user API key | user tokens | provider-dependent | user account | iOS 27 |

## 5. Mapping: what exists today → what it becomes

| iOS 26 (shipped) | iOS 27 (extension) |
|---|---|
| `OnDeviceProvider` | unchanged |
| `OpenAIProvider` (URLSession) | provider conforming to the `LanguageModel` protocol |
| `ModelPreference` (4 cases, deliberately frozen) | per-need fallback chain + PCC quotas |
| `resolveProvider()` (D9) | `preferred(_ need:)` returning a `LanguageModel` for Dynamic Profiles |
| `PrivacyDisclosure` (live since 26) | unchanged; `.appleCloud` level becomes reachable (PCC) |
| `ProviderError.isRecoverableByFallback` | extended with quota-specific cases (pending Q2/Q4) |
| D13 capability surface (`contextSize`/`tokenCount`) | per-model token reading lands here (pending Q10) |
| `ChatTurn` history (D12) | answers transcript portability across providers (pending Q6/Q7 for KV-cache) |
| — | `PrivateCloudComputeProvider` |
| — | user-account providers (Gemini/Claude) + model picker UI |

## 6. Implementation order (when unblocked)

Matches the roadmap in CLAUDE.md:
1. `PrivateCloudComputeProvider`, then user-account Gemini/Claude via the
   `LanguageModel` protocol; wire them into the ordered list in
   `buildProviders` (the only place that changes).
2. Runtime fallback chain keyed on need (`.lightweight/.reasoning/.largeContext`),
   replacing/extending `ModelPreference` (kept at 4 cases on purpose — a third
   provider makes a closed enum combinatorial).
3. `preferred(_ need:)` bridge for Dynamic Profiles, evolving `resolveProvider()`.
4. Model picker component in VoltaSDKUI (meaningful once >1 user-visible
   option; `ProviderStatusList` is the embryo).

## 7. Blockers

Implementation is gated on:
- **The iOS 27 SDK** (Xcode beta) — nothing compiles before that.
- **The open questions** in `docs/iOS27-OpenQuestions.md` (PCC quota semantics,
  transcript portability, `LanguageModel` conformance requirements, …). When
  answered, merge the answers into this file and delete that one.
