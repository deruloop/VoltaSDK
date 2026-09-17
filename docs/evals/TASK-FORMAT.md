# Task file reference (VoltaSDKEvals)

A **task** describes one model feature of an app so `VoltaSDKEvals` can
measure it: the prompt the app sends, the answer shape it expects, the
inputs users type, and the rules that make an answer correct. This is the
complete, authoritative description of the format. If a task follows it,
the engine accepts it; if the engine rejects a task, the error names the
field and the reason using the terms below.

A task is a JSON file (`task.schema.json` next to this document validates
one) or, in Swift, an `EvalTask` built with typed initializers; the two are
the same data. `EvalTask.examples` returns the shipped examples to copy:
two small ones (city facts, a packing list kept across turns) and five
long-context ones at growing page lengths.

## 1. Top level

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Stable identifier, e.g. `myapp.meal-record`. The capability map keys rows by it. Use `<app>.<feature>`. |
| `title` | string | yes | Human title, shown in the map. |
| `schemaVersion` | string | yes | Version of the prompt + shape this dataset was written for, e.g. `v1`. Change it when either changes, and re-run. |
| `instructions` | string | yes | The system instructions **verbatim**, exactly as the app sends them. Do not tidy them; the point is to measure what ships. |
| `language` | string | no | BCP-47 language the prose fields must come back in (`it`, `en`). Used by the `language` grader. |
| `schema` | schema object | no | The JSON shape expected back (section 2). Needed for the `schema` and `expect-shape` graders and for structured mode. |
| `carry` | object | no | How a later turn's prompt is built from the previous answer (section 4). |
| `graders` | array of grader objects | yes | The rules (section 3). A sample passes only if every grader passes. |
| `judge` | object | no | Dimensions for a model judge (section 5). |
| `samples` | array of sample objects | yes | The dataset (section 6). |

Minimal valid task:

```json
{
  "id": "example.city-facts",
  "title": "City facts as JSON",
  "schemaVersion": "v1",
  "language": "en",
  "instructions": "You are a concise geography assistant. Reply with ONLY a JSON object …",
  "schema": { "type": "object", "name": "CityFacts", "properties": [
    { "name": "city", "schema": { "type": "string" } },
    { "name": "country", "schema": { "type": "string" } },
    { "name": "continent", "schema": { "type": "string", "enum": ["Europe", "Asia", "Africa", "Americas", "Oceania"] } },
    { "name": "note", "schema": { "type": "string" } } ] },
  "graders": [ { "kind": "json-only" }, { "kind": "schema" }, { "kind": "expect-fields" }, { "kind": "language", "params": { "path": "note" } } ],
  "samples": [
    { "id": "c-01", "turns": ["Tell me about Rome"], "expect": { "fields": { "country": ["Italy"], "continent": ["Europe"] } } }
  ]
}
```

## 2. Schema

The `schema` field is VoltaSDK's `OutputSchema` in JSON form. It is
deliberately a small subset of JSON Schema: the shapes every backend can
constrain (guided generation on Apple models, JSON mode on cloud vendors).

| `type` | Extra fields | Notes |
|---|---|---|
| `object` | `name` (string, required), `properties` (array, ordered), `description` | Property order matters: Apple's guided generation fills fields in this order. |
| `string` | `enum` (array of strings), `pattern` (regex), `description` | `enum` is enforced natively; `pattern` is enforced by the SDK after the call. |
| `number`, `integer`, `boolean` | `description` | |
| `array` | `items` (schema, required), `min`, `max`, `description` | Bounds are enforced by the SDK after the call. |
| `anyOf` | `name` (string, required), `choices` (array of schemas), `description` | For answers that may take one of several shapes. Each choice should be an object with a distinct property set. |

A property is `{ "name": "…", "schema": { … }, "optional": true|false, "description": "…" }`; `optional` defaults to false. Objects are strict: extra keys are not allowed by the vendors' native modes.

Example with two shapes:

```json
{ "type": "anyOf", "name": "Reply", "choices": [
  { "type": "object", "name": "Record", "properties": [
    { "name": "items", "schema": { "type": "array", "min": 1, "items": { "type": "object", "name": "Item", "properties": [
      { "name": "name", "schema": { "type": "string" } },
      { "name": "kind", "schema": { "type": "string", "enum": ["a", "b"] } } ] } } },
    { "name": "note", "schema": { "type": "string" } } ] },
  { "type": "object", "name": "Action", "properties": [
    { "name": "add", "schema": { "type": "array", "min": 1, "items": { "type": "string" } } },
    { "name": "note", "schema": { "type": "string" } } ] } ] }
```

## 3. Graders

A grader is `{ "kind": "<kind>", "params": { … } }`. `params` may be
omitted when the grader takes none. Every grader accepts an optional
`params.name` that renames its metric column (default: the kind, plus
`:<path>` when a path is given), and an optional `params.whenPrompt`, a
case-insensitive regex: the grader applies only to samples whose typed
input matches it and is ignored for the others (a recipe page with no
amounts cannot yield amount-like quantities). In Swift,
`.elementsMatch(...).when(promptMatches: "\\d")`. All graders look at the last turn's
answer; `retention` looks at the first and the last.

| kind | params | Passes when | Swift |
|---|---|---|---|
| `json-only` | `allowFences` (bool, default true) | The reply is one JSON object, no prose around it. A bare ```` ``` ```` fence is tolerated by default. | `.jsonOnly()` |
| `schema` | | The parsed value validates against the task `schema`. | `.schema()` |
| `required` | `paths` (array of strings, required) | Each path is present and non-blank. An array entry may carry bounds: `"items:1"` (min 1), `"completions:1:3"` (min 1, max 3). | `.required(paths:)` |
| `forbidden-fields` | `paths` (required) | None of the paths is present or non-empty. | `.forbiddenFields(paths:)` |
| `expect-fields` | | For samples with `expect.fields`: each path's value is one of the allowed values (case-insensitive). Other samples: ignored. | `.expectFields()` |
| `expect-contains` | | For samples with `expect.contains`: the array at each path contains every listed element, after normalization (lowercased, accents folded, leading articles stripped, spaces ignored, substring either way). | `.expectContains()` |
| `expect-shape` | | For samples with `expect.shape`: the answer carries the required properties of the named `anyOf` choice. | `.expectShape()` |
| `language` | `path`, `language` (BCP-47), `minWords` (default 4) | The text at `path` (or the whole reply) is detected as `language` (default: the task's). Texts under `minWords` words are ignored. | `.language(path:)` |
| `forbidden-patterns` | `path`, `patterns` (array of regex, required) | No pattern matches the text at `path` (or the whole reply). Case-insensitive. | `.forbiddenPatterns(path:patterns:)` |
| `elements-match` | `path` (required), `pattern` (required), `minFraction` (default 1.0) | At least that fraction of the array's elements match the regex. | `.elementsMatch(path:pattern:minFraction:)` |
| `claimed-action` | `field` (required), `patterns` (required) | Fails when a pattern matches the reply's text while `field` is absent or an empty array: the model *said* it did something it did not encode. | `.claimedAction(field:patterns:)` |
| `retention` | `keepItems` (a `[]` path), `keepStates` (object path), `from`, `notTo` | The last turn keeps every `keepItems` value from the first turn; no `keepStates` member drops from `from` to `notTo`. Needs two-turn samples. | `.retention(keepItems:keepStates:from:notTo:)` |

**Paths** are dot paths into the answer: `note`, `compounds.protein`,
`items[0].name`. `items[].name` collects one value per element.

**Infrastructure failures** (unsupported language, model unavailable,
rate limit, network, context window) make every grader ignore the sample.
They are reported separately as `model-available` and `language-accepted`
rates, so a pass rate measures the model and never the plumbing. A
model-side failure (no JSON, malformed after repair, a guardrail) counts
as a fail.

## 4. Carry (multi-turn tasks)

For samples with more than one turn, `carry.template` builds the prompt of
turn N from the parsed answer of turn N-1. Without `carry`, later turns are
sent as typed and the conversation history carries the context.

Placeholders:

| Placeholder | Renders as |
|---|---|
| `{{prompt}}` | the user's text for this turn |
| `{{previous.raw}}` | the previous raw answer text |
| `{{previous.json}}` | the previous parsed value, compact JSON |
| `{{previous.<path>}}` | the value at a path; strings unquoted, other values compact JSON |
| `{{previous.<path>\|join:<fmt>\|sep:<s>}}` | an array rendered element by element with `<fmt>`, where `{field}` reads an element's field (`{value}` for scalar arrays), joined by `<s>` (default `, `) |

When the previous turn produced nothing parseable, the sample's
`canonicalState` stands in, and the outcome records that it did. Example,
the wrapper an app really sends:

```json
"carry": { "template": "Ripieno so far: [{{previous.items|join:{name} ({compound})|sep:, }}]. Compounds {{previous.compounds}}. The person now says: {{prompt}}" }
```

## 5. Judge (optional)

For qualities a rule cannot check, a cloud model from a vendor other than
the one under test scores dimensions (WWDC 2026, session 335):

```json
"judge": {
  "instructions": "optional override of the judge's system prompt",
  "dimensions": [
    { "name": "warmth", "description": "The note is warm and non-judgmental, in Italian, with no numbers or diet talk." },
    { "name": "accuracy", "description": "…", "scale": { "1": "wrong", "3": "partly right", "5": "right" } }
  ]
}
```

A dimension without `scale` is pass/fail. The judge runs only when a
judge key is configured, and its scores are recorded separately from the
deterministic pass rate. Its agreement with human ratings (Cohen's kappa)
is measured before it is trusted; see the README.

## 6. Samples

```json
{
  "id": "a-01",
  "turns": ["Crackers e formaggio"],
  "expect": {
    "shape": "Record",
    "fields": { "compounds.protein": ["present", "light"] },
    "contains": { "items[].name": ["crackers", "formaggio"] }
  },
  "canonicalState": { "items": [ { "name": "crackers", "kind": "a" } ] },
  "notes": "why this sample exists"
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique within the task. |
| `turns` | yes | The user's text, one string per turn, as typed in the app. One turn for single-shot tasks. |
| `expect.fields` | no | path → allowed values. Read by `expect-fields`. |
| `expect.contains` | no | array path → required elements. Read by `expect-contains`. |
| `expect.shape` | no | The `anyOf` choice name the answer must take. Read by `expect-shape`. |
| `canonicalState` | no | Fallback previous answer for the carry template when turn N-1 failed. |
| `notes` | no | Free text; shown to the judge as context. |

Guidance for a useful dataset: twenty inputs for a single-turn feature,
written the way users write (typos, dialect, no punctuation), including a
few deliberately ambiguous ones with no expectation, so the map shows how
the model resolves them. Keep expectations to what a human would insist
on; the graders are strict and every expectation is a rule.

## 7. Modes and what they measure

The same task runs in three modes. `raw` sends `instructions` and the turn
as the app does today and parses whatever comes back: the ceiling of the
prompt as written. `structured` sends the same call through VoltaSDK's
`respondStructured` with the task `schema`, no repair. `structured+repair`
allows one repair turn. Comparing the columns shows what structured output
buys on each tier.

## 8. Errors the loader reports

`EvalTask.load(from:)` validates and throws `EvalEngineError.invalidTask`
with one line per problem, for example:

```
invalid task task-a.json:
  graders[3].kind: unknown grader "langauge"; known: json-only, schema, …
  graders[2].params.paths: required needs "paths"
  samples[4].id: duplicate id "a-04"
  samples[7].expect.shape: "Shoping" is not one of the schema's anyOf choices ["Record", "Action"]
  carry: a carry template needs at least one multi-turn sample
```

## 9. Checklist

- `instructions` copied verbatim from the app, not rewritten.
- `schema` mirrors the shape the app's parser accepts; property order as the app expects it.
- `schemaVersion` bumped whenever instructions or schema change.
- Every grader kind is in section 3 and has its required params.
- `language` set at task level when any `language` grader is used.
- Sample ids unique; every sample has at least one non-empty turn.
- Two-turn samples for `retention`, with `carry` if the app wraps the previous state into the prompt.
- Ambiguous inputs included without expectations.
- The file validates against `task.schema.json`.
