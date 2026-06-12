# VoltaSDK — iOS 27 Open Questions

> Things we must learn before implementing the iOS 27 extension (raised for the
> WWDC Group Labs). **Temporary file:** as answers arrive, fold them into
> `docs/iOS27-Design.md` and remove the question here; delete this file when
> empty. Until the high-priority block is answered, iOS 27 work stays
> design-only.

---

## High priority — they unblock the fallback architecture

- **Q1:** Is PCC remaining quota readable *before* a call (proactive), or only via an
  error at call time (reactive)? Determines the whole selection strategy.
- **Q2:** What error does `PrivateCloudComputeLanguageModel` throw on quota exhaustion?
  Is it a distinct type (vs network/server-busy) so fallback only fires in the right case?
- **Q3:** When does the daily PCC quota reset — local midnight, UTC, or rolling 24h?
- **Q4:** How to distinguish "this user is out of quota" from "PCC temporarily down"?

## Composition / sessions

- **Q5:** Can a runtime-chosen `LanguageModel` be passed to `.model(...)` inside a Dynamic
  Profile, or is a Profile's model fixed once declared?
- **Q6:** If PCC quota runs out mid-conversation, can the same session continue on another
  model preserving the transcript, or must it be recreated? *(Partially answered
  by design: D12 transcript transparency makes every call self-contained, so
  provider switching works today by replaying app-supplied history. Still open:
  whether Apple offers native session migration with KV-cache preservation.)*
- **Q7:** Is the transcript/KV-cache portable across different models (PCC → on-device)?

## Providers / Utilities / capabilities

- **Q8:** Utilities' Chat Completions `LanguageModel` — point at any compatible endpoint
  with URL+key? What does it expose, especially token counts?
- **Q9:** Minimum requirements to conform a custom provider to `LanguageModel`
  (streaming / tool calling mandatory or optional)?
- **Q10:** Uniform token-usage reading across models, or per-implementation?
  *(Our D13 capability surface — `contextSize`/`tokenCount` on `ModelProvider` —
  is where the answer lands either way.)*
- **Q11:** Official runtime availability API for on-device + reasons.
- **Q12:** Feature parity (Generable, tool calling, reasoningLevel) across models — risk of
  losing structured output on fallback?
- **Q13:** Token cost predictability with guided generation.

## Distribution

- **Q14:** PCC entitlement + application process/timeline; test environment before approval?
- **Q15:** PCC behavior in TestFlight / debug; different quotas in dev vs prod?
- **Q16:** Regional restrictions (EU/China) the framework must treat as "unavailable"?

## General validation

- **Q17:** "I'm building a layer that gives an orchestrator to Dynamic Profiles, resolving
  at runtime which LanguageModel to use based on user choice, auth, quota and availability,
  with automatic fallback down to on-device. Any pitfalls or edge cases I'm missing?"
