# Evaluations (D20): how to run

The engine lives in the opt-in test target `Tests/VoltaSDKEvals` and runs a
generic triple, a **task** = schema + dataset + graders, through any tier of
the chain, under Apple's Evaluations framework. The first client triple
(Raviolo) stays in the client's own files, consumed by path; the engine
ships with two small generic example tasks under `Tests/VoltaSDKEvals/Fixtures`.

## The triple, as data

A task file is JSON:

```json
{
  "id": "example.city-facts", "title": "…", "schemaVersion": "v1", "language": "en",
  "instructions": "…verbatim, as the app sends them…",
  "schema": { "type": "object", "name": "CityFacts", "properties": [ … ] },
  "carry": { "template": "List so far: [{{previous.items|join:{value}|sep:, }}]. The person now says: {{prompt}}" },
  "graders": [ { "kind": "json-only" }, { "kind": "schema" }, { "kind": "expect-fields" } ],
  "judge": { "dimensions": [ { "name": "note-quality", "description": "…" } ] },
  "samples": [ { "id": "c-01", "turns": ["Tell me about Rome"], "expect": { "fields": { "country": ["Italy"] } } } ]
}
```

- `schema` is the SDK's `OutputSchema` in its JSON form (D21). Objects keep
  property order; `anyOf` expresses answers that may take one of several
  shapes.
- `carry` builds turn N's prompt from turn N-1's parsed output (multi-turn
  tasks). Placeholders: `{{prompt}}`, `{{previous.raw}}`, `{{previous.json}}`,
  `{{previous.<path>}}`, `{{previous.<path>|join:<fmt>|sep:<s>}}`. A sample's
  `canonicalState` stands in when the previous turn produced nothing usable.
- `expect` per sample: `fields` (path → allowed values), `contains` (array
  path → required elements, normalized), `shape` (which `anyOf` choice).
- `graders` compose PASS from the registry below; `pass` for a sample is the
  AND of all graders.

## Grader registry

| kind | params | passes when |
|---|---|---|
| `json-only` | `allowFences` (default true) | the reply is one JSON object, no prose around it |
| `schema` | | the parsed value validates against the task schema |
| `required` | `paths` (`name`, `array:min:max`) | fields present, non-blank, arrays within bounds |
| `forbidden-fields` | `paths` | none of the paths is present / non-empty |
| `expect-fields` | (per-sample `expect.fields`) | each path's value is one of the allowed values |
| `expect-contains` | (per-sample `expect.contains`) | each array contains every required element |
| `expect-shape` | (per-sample `expect.shape`) | the answer takes the named `anyOf` choice |
| `language` | `path`, `language`, `minWords` | the prose at the path is in the task's language (NLLanguageRecognizer) |
| `forbidden-patterns` | `path`, `patterns` | no regex matches (case-insensitive) |
| `elements-match` | `path`, `pattern`, `minFraction` | enough array elements match the regex |
| `claimed-action` | `field`, `patterns` | the reply does not claim an action in prose while lacking the action field |
| `retention` | `keepItems`, `keepStates`, `from`, `notTo` | later turns keep earlier items and states |

Infrastructure failures (unsupported language, unavailability, rate limits,
network, context window) make every grader `ignore` the sample; they are
reported as `model-available` / `language-accepted` rates instead, so pass
rates measure the model, never the plumbing. A model-side failure (no JSON,
malformed after repair, guardrail) is a FAIL.

## Tiers and modes

Tiers (`VOLTA_EVAL_TIERS`): `on-device`, `pcc`, `cloud-openai`,
`cloud-anthropic`, `cloud-gemini`. Each tier is a single provider in a
one-element chain, so provenance is exact.

Modes (`VOLTA_EVAL_MODES`): `raw` (the app's prompt, verbatim: the raw
ceiling), `structured` (the SDK's `respondStructured` with the task schema,
no repair), `structured+repair` (one repair turn).

## Running

```bash
# CI-safe engine tests (mock-backed), part of `swift test`
DEVELOPER_DIR=~/Downloads/Xcode-beta.app/Contents/Developer swift test --filter VoltaSDKEvals

# Live, on this Mac (on-device = the Mac's Apple Intelligence; cloud with keys)
VOLTA_EVAL_LIVE=1 VOLTA_EVAL_TASKS=docs/evals/raviolo/tasks \
VOLTA_EVAL_TIERS=on-device VOLTA_EVAL_MODES=raw,structured,structured+repair \
DEVELOPER_DIR=… swift test --filter LiveEvaluations
```

Environment: `VOLTA_EVAL_LIVE=1`, `VOLTA_EVAL_TASKS` (file or directory),
`VOLTA_EVAL_TIERS`, `VOLTA_EVAL_MODES`, `VOLTA_EVAL_LIMIT` (samples per task),
`VOLTA_EVAL_RESULTS` (default `docs/evals/results`), `VOLTA_EVAL_HOST`
(label), `VOLTA_EVAL_<OPENAI|ANTHROPIC|GEMINI>_KEY` / `_MODEL`,
`VOLTA_EVAL_MAX_TOKENS`, `VOLTA_EVAL_JUDGE_KEY` / `_VENDOR` / `_MODEL`,
`VOLTA_EVAL_HUMAN_RATINGS`.

### PCC: the hosted bundle in the signed macOS demo

A `swift test` process is unentitled, so the PCC tier can only be measured
from a process signed with the entitlement. `Examples/macOSDemo` carries a
`macOSDemoEvals` unit-test bundle hosted by the (locally entitled) demo app;
the bundle compiles the SAME engine sources and carries the task files as a
folder reference (`../../docs/evals/raviolo/tasks`, optional). `xcodebuild`
forwards `TEST_RUNNER_`-prefixed **environment variables** (not build
settings) to the test process:

```bash
cd Examples/macOSDemo
export TEST_RUNNER_VOLTA_EVAL_LIVE=1 TEST_RUNNER_VOLTA_EVAL_TIERS=pcc \
       TEST_RUNNER_VOLTA_EVAL_MODES=raw,structured,structured+repair
DEVELOPER_DIR=… xcodebuild test -scheme macOSDemoEvals -destination 'platform=macOS' \
  "-only-testing:macOSDemoEvals/LiveEvaluations/capabilityMap()" 2>&1 | tee run.log
python3 ../../scripts/evals-merge.py run.log ../../docs/evals/results/capability-map.json
```

A GUI host app must not touch the repo: reading or writing under
`~/Desktop`, `~/Documents`, or `~/Downloads` blocks on macOS's privacy
prompt and the run hangs. The hosted runner therefore reads tasks from the
bundle, writes to `~/Library/Application Support/VoltaSDKEvals/results`,
and prints each entry as an `[evals-entry]` line for the merge script.

### A real iPhone: the hosted bundle in the iOS demo

The Mac's model only stands in for a phone's. `Examples/iOSDemo` carries an
`iOSDemoEvals` bundle with the task files bundled as a folder reference
(`../../docs/evals/raviolo/tasks`, optional, git-excluded client data).
Results land in the app container and are printed as `[evals-entry]`
lines; merge them on the Mac:

```bash
cd Examples/iOSDemo
export TEST_RUNNER_VOLTA_EVAL_LIVE=1 TEST_RUNNER_VOLTA_EVAL_TIERS=on-device
DEVELOPER_DIR=… xcodebuild test -scheme iOSDemoEvals -destination 'id=<udid>' \
  "-only-testing:iOSDemoEvals/LiveEvaluations/capabilityMap()" 2>&1 | tee run.log
python3 ../../scripts/evals-merge.py run.log ../../docs/evals/results/capability-map.json
```

## Output

`docs/evals/results/capability-map.json` (+ `.md`): one entry per
(task, tier, mode) with pass rate, availability, per-grader rates, a few
failure rationales, latency, and judge dimensions when a judge ran. Entries
are upserted, so the map accumulates across machines. The framework's own
run records (`runs/*.xcevalresult`, transcripts included) stay local.

## The judge (session 335)

A task may declare `judge.dimensions`. With `VOLTA_EVAL_JUDGE_KEY` set, a
cloud model from that vendor scores them through `ModelJudgeEvaluator`,
reached as a native `LanguageModel` via VoltaSDK's `CloudAccountLanguageModel`
(the iOS 27 front door). Rules: the judge never scores its own vendor's
tier, and it is not trusted until `VOLTA_EVAL_HUMAN_RATINGS`
(`{"task":…,"ratings":{"<sample>":{"<dimension>":1}}}`) has produced a
Cohen's kappa against human ratings, recorded next to the dimension means.

Keep the iPhone **unlocked with the host app in the foreground** for the
whole run: the on-device model rate-limits background callers, and a
locked phone turns every call after the first into `rateLimited` (reported
as availability, so the pass rate stays honest, but the run measures
nothing).
