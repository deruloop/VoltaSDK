# VoltaSDK — Project Context

> Entry point for working on this project. The detailed documentation is split
> into dedicated artifacts (map below); this file holds the working agreement,
> the current state, and the roadmap.
> **Working agreement: every code change must update the relevant doc(s) in the
> same session** — this index, the implementation/design docs, and CHANGELOG on
> release. (Language note: **everything is in English** — docs, code comments,
> and user-facing strings — as of v1.0.1.)

---

## 1. TL;DR — what this is

VoltaSDK (**VOLTA** = *Versatile Orchestration Layer for Tiered AI*; named
after Alessandro Volta — battery = stacked cells = fallback chain) is a
Swift Package that **resolves
which AI model to use** at runtime (on-device Foundation Models vs a
vendor-agnostic developer key — OpenAI, Claude, or Gemini — today; PCC and
user-account providers on iOS 27) with
automatic fallback, privacy disclosure, transcript-transparent conversations,
and token awareness. It does **not** invent an agent abstraction — on iOS 27
it *feeds* Apple's native Dynamic Profiles rather than wrapping them. One
stable public API across all phases (SemVer: 0.x during development; **1.0.0
is reserved for the complete feature set, including iOS 27**).

## 2. Documentation map

| Artifact | Audience | Content |
|---|---|---|
| `README.md` | public (GitHub) | what it is, **version support tiers (26.0 / 26.4 / 27)**, SPM installation, usage, demos |
| `docs/iOS26-Implementation.md` | internal | how the **shipped** iOS 26 + 26.4 tiers are implemented: file map, decisions D4–D5, D7–D13, D15, stable API, verification, troubleshooting |
| `docs/iOS27-Design.md` | internal | how iOS 27 **will** be implemented: decisions D1–D3, D6, D14, capability split, provider table, mapping, implementation order |
| `docs/iOS27-OpenQuestions.md` | internal, temporary | Q1–Q17 gating iOS 27 work; answers get merged into the design doc, then this file is deleted |
| `CHANGELOG.md` | public | SemVer release notes |

Rule of thumb: change shipped code → update the iOS 26 doc; take an iOS 27
decision → update the design doc; learn an iOS 27 answer → move it from the
questions doc into the design doc; release → CHANGELOG + state here.

## 3. Current state (June 2026)

- **Versioning policy (user decision, June 2026): 1.0.0 is reserved for the
  complete feature set, including iOS 27.** The earlier 1.0.0/1.0.1/2.0.0
  tags were deleted (never pushed anywhere); current release line is **0.x**,
  starting at `0.1.0`. During 0.x, minor versions may evolve the API.
- **iOS 26 / 26.4: fully working — v0.3.0** (tags `0.1.0`–`0.3.0`,
  2026-06-12; 0.2.0 = vendor-agnostic developer key D15, 0.3.0 = collapsed
  ModelSelector with `.activate/.deny/.deferred` selection responses).
  41 tests in 8 suites green; builds verified on macOS 26.5, iOS 26.5
  simulator, and signed for a physical iPhone. First adoption in the author's
  app is in progress. The 26.4 token-aware tier lights up by itself at
  runtime; on 26.0–26.3 context handling stays reactive-only, by design.
- **iOS 27: designed, NOT implemented — zero iOS 27 code exists.** The design
  is substantial (see `docs/iOS27-Design.md`: founding decisions, provider
  table, tiering strategy D14, implementation order) but implementation is
  blocked on (a) the open questions in `docs/iOS27-OpenQuestions.md` and
  (b) the iOS 27 SDK, without which nothing compiles.
- No git remote configured yet; the package is consumed locally.

## 4. Core principles (one-liners; full rationale in the linked docs)

- **D1/D2** Feed Dynamic Profiles, never own "agent" — we do model resolution. *(27 design)*
- **D3** One stable API; iOS 27 lights up additively. *(27 design)*
- **D4** Developer key = AI included in the app's subscription. *(26 impl)*
- **D5** On-device is never assumed present. *(26 impl)*
- **D6** PCC = free tier with runtime-exhaustible quota → fallback must be runtime. *(27 design)*
- **D7** Per-call re-resolution + privacy threshold disclosure. *(both)*
- **D8** Type is `AIOrchestrator` (module/type shadowing). *(26 impl)*
- **D9** `resolveProvider()` is the primitive; `respond` is convenience. *(26 impl)*
- **D10** Privacy disclosure shipped in 26, not 27. *(26 impl)*
- **D11** UI optional by construction; core never imports SwiftUI. *(26 impl)*
- **D12** Stateless core, transcript-transparent: app owns history, every call self-contained. *(26 impl)*
- **D13** Token awareness as optional capability + orchestrator pre-flight. *(26 impl)*
- **D14** One package, three capability tiers — expression-level gates for 26.4, type-level gates for 27. *(27 design)*
- **D15** Vendor-agnostic developer key: OpenAI/Claude/Gemini in one slot, auto-detected; model name travels with the key. *(26 impl)*

## 5. Roadmap (ordered)

1. ~~Compile & green the tests~~ ✅
2. ~~Privacy disclosure~~ ✅ (D10)
3. **Streaming.** Add `streamResponse` to `ModelProvider` and both providers
   (OpenAI via SSE `"stream": true`). Design question: stream vs fallback
   (fail before first token = fall through; fail mid-stream = surface).
4. ~~Token/context awareness~~ ✅ (D13)
5. ~~Multi-turn~~ ✅ (D12) — still open, lower priority: KV-cache/`Transcript`
   reuse when the provider didn't change between turns; trimming hook pairs
   with `contextUsage`.
6. **iOS 27 providers** (PCC, then Gemini/Claude) — blocked, see
   `docs/iOS27-Design.md` §7.
7. **Per-need fallback chain** (`.lightweight/.reasoning/.largeContext`) —
   blocked with 6.
8. **`preferred(_ need:)` bridge** for Dynamic Profiles — blocked with 6.
9. ~~Model picker component~~ ✅ (June 2026): `ModelSelector` in VoltaSDKUI —
   collapsed user-side picker; selection answered by the app with
   `.activate`/`.deny`/`.deferred` (deferred = app-owned flow commits later
   via the binding — the iOS 27 OAuth-page pattern). iOS 27 providers will
   appear in it automatically once wired into `buildProviders`.
10. **Fetch model lists from vendor APIs** (OpenAI/Anthropic `GET /v1/models`,
    Gemini `ListModels`): once a key is entered, populate a model picker for
    the developer instead of a free-text field. Complements D15.
