# Evaluations (D20): how it works, how to use it

`VoltaSDKEvals` is a library you add to your app's **test target**. It runs
one of your app's model features, many times, against one model tier, and
counts how often the answer meets your rules. Nothing in your app runs;
only its prompt does.

## How it works (the actors)

- **Your prompt.** The system instructions your app sends, verbatim, and
  the JSON shape it expects back. They go into a *task*.
- **Your dataset.** Twenty or so inputs a user would type, each with what a
  correct answer must contain. Also in the task.
- **The model under test.** One VoltaSDK provider you pick in code:
  `OnDeviceProvider()`, `PrivateCloudComputeProvider()`, or a developer-key
  provider. VoltaSDK is called exactly as your app would call it.
- **The graders.** Small deterministic rules from a fixed registry (is the
  reply only JSON, does it match the schema, is the note in Italian, did
  the model keep the items from the previous turn). Each returns pass or
  fail with a reason.
- **Apple's Evaluations framework** (WWDC 2026, session 298). The
  conductor: it loops over the dataset, calls VoltaSDK for each input, hands
  the answer to the graders, averages the metrics, and saves every prompt,
  answer, and verdict to an `.xcevalresult` file.
- **The capability map.** The table the averages land in, one row per
  model tier, one column per mode.

For one input the flow is: the framework takes the sample; the engine sends
your instructions plus the sample to the provider (`respond`, or
`respondStructured` in structured mode); the model answers; each grader
inspects the answer; the sample passes only if every grader passes; the
framework moves to the next sample. At the end it averages, and the engine
writes the row.

## Your flow as an adopter

1. **Add the product** to your app's test target (`VoltaSDKEvals`, from the
   same package as `VoltaSDK`).
2. **Write a task** for each model feature: a JSON file next to your tests
   (or the same thing in Swift). Copy `EvalTask.examples` to start.
3. **Write a test** that runs it against the provider you ship with, in the
   mode you ship with, and asserts on the pass rate:

```swift
import Testing
import VoltaSDK
import VoltaSDKEvals

@Suite struct MealRecordEvals {
    let task = try! EvalTask(contentsOf: Bundle.module.url(forResource: "meal-record", withExtension: "json")!)

    @Test func onDeviceStructured() async throws {
        guard #available(iOS 27, macOS 27, *) else { return }   // the framework is OS 27+
        let result = try await TaskEvaluation(task: task, provider: OnDeviceProvider(), mode: .structured).run()
        #expect(result.passRate >= 0.6, "\(result.failureReasons)")
    }
}
```

4. **Run it with Cmd-U** (or `swift test`). A failing test prints the
   reasons the graders recorded, one per failed sample.
5. **Decide from the numbers.** Where the shape fails, switch that call to
   `respondStructured` with the same schema. Where a tier cannot do a
   feature at all, gate it or change the design. Keep a `CapabilityMap`
   if you want the table across tiers (`CapabilityMap.entry(from:evaluation:host:judge:)`).

Session 298 also shows the Swift Testing trait form,
`@Test(.evaluates(TaskEvaluation(...)))`; it works the same way, since
`TaskEvaluation` is a plain `Evaluation`.

### From numbers to decisions (the pattern)

The map is only useful if the app changes because of it. The loop that
worked on the first client, and the one this library is built around:

1. **Measure the prompt as it ships** (`raw` mode). The floor, with the
   graders naming the cause of every failure.
2. **Fix shape with the SDK, never with prompt edits.** When the failures
   are structural (wrong enum values, missing fields, prose around the
   JSON), switch that call to `respondStructured` with the task's schema
   and re-run in `structured` mode. Shape failures should disappear; what
   remains is content.
3. **Split what a small model cannot do inside a big prompt.** When a
   branch or a classification fails at 0% inside the assistant prompt, add
   a task for the same decision as its own one-field call and measure it.
   If it passes, the app makes two calls.
4. **Gate by tier.** The map says which tier clears which feature. Bundle
   `capability-map.json` in the app, set `AIConfiguration.capabilities`,
   and name the task on each call (`task: TaskRequirement("myapp.meal-record")`);
   the chain skips a provider that measured below the floor for that task
   and mode, and `canServe` answers whether the feature can exist on this
   device's chain at all. Unmeasured providers are always tried.
5. **Keep the floors as tests.** One `@Test` per feature per shipped tier,
   asserting the measured pass rate, so a prompt edit or an OS update that
   regresses shows up with reasons attached.
6. **Measure before wiring.** Every new prompt the app is about to ship gets
   a task and a number first, even a small one. Twenty samples and two
   minutes on-device are cheaper than a release.

### Where things live

- Your tasks and your results: in **your** repo, next to your tests.
- The engine, the grader registry, and two example tasks: this package.
- VoltaSDK's own sweep across every tier (the environment-variable runner
  described below): this package's `Tests/VoltaSDKEvalsTests`. It is how the
  SDK produces its capability map for the articles; adopters do not need it.

## The task file

The complete field-by-field reference is **[TASK-FORMAT.md](TASK-FORMAT.md)**,
and `task.schema.json` next to it validates a task file in an editor or a
script. Write a task from that document; the loader reports any problem
as `path: reason`. What follows is the short form.

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
| `expect-forbids` | (per-sample `expect.forbids`) | nothing at each path matches a listed element; the sample's own exclusion |
| `expect-contains-any` | (per-sample `expect.containsAny`) | at least one listed element at each path; any of several right answers |
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
malformed after repair, guardrail) is a FAIL. A rate limit is waited out
first: the turn is retried up to `rateLimitRetries` times (default 4),
pausing for the provider's `retryAfter` or 20 s, so a free-tier cloud key
(five requests a minute on Gemini) measures the model, slowly, instead of
the quota. The outcome records how many waits an answer needed.

## Tiers and modes

Tiers (`VOLTA_EVAL_TIERS`): `on-device`, `pcc`, `cloud-openai`,
`cloud-anthropic`, `cloud-gemini`. Each tier is a single provider in a
one-element chain, so provenance is exact.

Modes (`VOLTA_EVAL_MODES`): `raw` (the app's prompt, verbatim: the raw
ceiling), `structured` (the SDK's `respondStructured` with the task schema,
no repair), `structured+repair` (one repair turn).

**Handoff (parity on fallback).** `VOLTA_EVAL_HANDOFF_TO=<tier>` also runs
every multi-turn task with turns after the first on that tier, the
app-owned history carried across, exactly what the chain does when it falls
back mid-conversation. The row is keyed `<tier>><handoff tier>` (for
example `on-device>pcc`), so the map shows whether quality holds when the
answer silently moves providers. In code: `TaskEvaluation(task:provider:
mode:handoff: .init(afterTurn: 1, to: otherProvider))`.

**Long context.** The engine ships five example tasks,
`example.long-context-2k` … `-16k`, that hide one recipe among others at
growing page lengths; run against a tier they show where it stops finding
the target and where the context window closes (reported as availability).

## VoltaSDK's own sweep (the environment-variable runner)

`EvalRunner` runs every task in a directory against every tier this process
can reach, in the requested modes, and upserts the map. Environment-driven
so the same code runs under `swift test` on the Mac and inside a hosted
test bundle on a device.

```bash
# CI-safe engine tests (mock-backed), part of `swift test`
DEVELOPER_DIR=~/Downloads/Xcode-beta.app/Contents/Developer swift test --filter VoltaSDKEvalsTests

# Live, on this Mac (on-device = the Mac's Apple Intelligence; cloud with keys)
VOLTA_EVAL_LIVE=1 VOLTA_EVAL_TASKS=/path/to/your/tasks \
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
the bundle links the same `VoltaSDKEvals` product and can carry task files
as a folder reference named `EvalTasks` (add your own; the SDK ships none).
`xcodebuild`
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
`iOSDemoEvals` bundle; add your task files as a folder reference named
`EvalTasks` (a client app keeps its tasks in its own repo, next to its own
eval test target).
Results land in the app container and are printed as `[evals-entry]`
lines; merge them on the Mac:

```bash
cd Examples/iOSDemo
export TEST_RUNNER_VOLTA_EVAL_LIVE=1 TEST_RUNNER_VOLTA_EVAL_TIERS=on-device
DEVELOPER_DIR=… xcodebuild test -scheme iOSDemoEvals -destination 'id=<udid>' \
  "-only-testing:iOSDemoEvals/LiveEvaluations/capabilityMap()" 2>&1 | tee run.log
python3 ../../scripts/evals-merge.py run.log ../../docs/evals/results/capability-map.json
```

A hosted sweep on a phone keeps the screen on (`isIdleTimerDisabled`)
for its whole duration: once the display sleeps the host app is a
background process and the system model answers `rateLimited` to every
call, which the engine records as unavailability, not failure. Run files
land in the host app's Documents; pull them with
`xcrun devicectl device copy from --domain-type appDataContainer
--domain-identifier <host bundle id> --source Documents/VoltaSDKEvals/results`.

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
