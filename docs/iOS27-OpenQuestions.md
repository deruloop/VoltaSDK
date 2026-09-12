# VoltaSDK — iOS 27 Open Questions

> Things we must learn before/while implementing the iOS 27 extension.
> **Temporary file:** as answers arrive, fold them into `docs/iOS27-Design.md`
> and remove the question here; delete this file when empty.
>
> **June 2026 — the high-priority block is answered from the iOS 27 SDK**
> (Xcode 27 beta 27A5209h); the answers now live in `docs/iOS27-Design.md` §8.
> Removed as answered: Q1, Q2, Q3, Q4 (PCC quota is proactively readable +
> distinct error cases), Q5 (runtime `LanguageModel` accepted by both
> `LanguageModelSession(model:)` and the Dynamic Profile `.model(_:)` modifier),
> Q6/Q7 (no native cross-model KV-cache migration — transcript replay per D12
> is the mechanism), Q9 (conformance = `LanguageModel` + `Executor`, streaming
> is the primitive, capabilities are declared), Q10 (uniform *post-call* usage
> via `LanguageModelSession.usage`; pre-call counting stays per-implementation),
> Q11 (availability APIs). What remains needs a real device, external accounts,
> or a separate package — not the SDK's API shape.

---

## Providers / Utilities / capabilities

- **Q8:** Utilities' Chat Completions `LanguageModel` — point at any compatible
  endpoint with URL+key? What does it expose, especially token counts?
  *(Not in `FoundationModels.framework`; it ships in the separate open-source
  `swift-foundation-models-utilities` package — needs adding as a dependency to
  inspect. May serve as the transport for the user-account Gemini/Claude
  providers instead of hand-writing an `Executor`.)*
- **Q12:** Feature parity (Generable, tool calling, reasoningLevel) across models —
  risk of losing structured output on fallback? *(Partly addressed: the SDK
  declares per-model `LanguageModelCapabilities` and throws
  `.unsupportedCapability` / `.unsupportedGenerationGuide`, so the orchestrator
  CAN check capabilities before routing. Still needs runtime validation of what
  each provider actually advertises.)*
- **Q13:** Token cost predictability with guided generation. *(Runtime.)*

## Distribution

- **Q14:** ~~PCC entitlement + application process/timeline; test environment~~
  **ANSWERED — see `docs/iOS27-Design.md` §8.** Key is
  `com.apple.developer.private-cloud-compute` (developer-side, assigned to the
  account); requested via `developer.apple.com/contact/request/private-cloud-compute/`;
  eligibility = App Store Small Business Program + < 2M downloads; testable via
  TestFlight / ad-hoc. Missing entitlement traps (uncatchable), so the provider
  gates on a `SecTask` self-check.
- **Q15:** PCC behavior in TestFlight / debug; different quotas in dev vs prod?
- **Q16:** Regional restrictions (EU/China) the framework must treat as
  "unavailable"?

## General validation

- **Q17:** "I'm building a layer that gives an orchestrator to Dynamic Profiles,
  resolving at runtime which LanguageModel to use based on user choice, auth,
  quota and availability, with automatic fallback down to on-device. Any pitfalls
  or edge cases I'm missing?"
