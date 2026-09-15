# Capability map

Generated 2026-09-15 12:03. Pass rate = passed / scored; scored excludes infrastructure failures (unsupported language, unavailability, rate limits), which show as availability.

## Raviolo Task A — ripieno read, single turn (`raviolo.task-a`, schema v1)

| Tier | Host | raw | structured | structured+repair |
|---|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 0% (0/20) | 65% (13/20) | 50% (10/20) |
| pcc | Mac M2, macOS 27.0 (26A5416b), entitled host | 70% (14/20) | 90% (18/20) | 85% (17/20) |

Graders (on-device, raw): expect-fields 9% · expect-shape 95% · forbidden-patterns:note 95% · json-only 100% · language:note 50% · required 90% · schema 0%

## Raviolo Task A (variant) — note described as Italian in the schema (`raviolo.task-a-note-it`, schema v1-it)

| Tier | Host | raw | structured |
|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 0% (0/20) | 65% (13/20) |

Graders (on-device, raw): expect-fields 0% · expect-shape 100% · forbidden-patterns:note 100% · json-only 100% · language:note 55% · required 95% · schema 0%

## Raviolo Task A′ — item retention across turns (`raviolo.task-a-prime`, schema v1)

| Tier | Host | raw | structured | structured+repair |
|---|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 0% (0/8) | 0% (0/8) | 25% (2/8) |
| pcc | Mac M2, macOS 27.0 (26A5416b), entitled host | 62% (5/8) | 88% (7/8) | 62% (5/8) |

Graders (on-device, raw): expect-contains 75% · expect-shape 75% · forbidden-patterns:note 75% · json-only 88% · language:note 12% · retention 88% · schema 0%

## Raviolo Task B — shopping intent reaching the model (`raviolo.task-b`, schema v1)

| Tier | Host | raw | structured | structured+repair |
|---|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 0% (0/20) | 0% (0/20) | 0% (0/20) |
| pcc | Mac M2, macOS 27.0 (26A5416b), entitled host | 80% (16/20) | 80% (16/20) | 80% (16/20) |

Graders (on-device, raw): claimed-action 80% · expect-contains 0% · expect-shape 0% · json-only 90% · language:note 85% · no-ripieno-fields 0% · schema 0%

## Raviolo Task B2 (proposal) — intent classification as a dedicated call (`raviolo.task-b2-intent`, schema v1-proposal)

| Tier | Host | raw | structured |
|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 89% (25/28) | 89% (25/28) |

Graders (on-device, raw): expect-fields 89% · json-only 100% · schema 100%

## Raviolo Task C — link → recipe extraction (`raviolo.task-c`, schema v1)

| Tier | Host | raw | structured | structured+repair |
|---|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 86% (6/7) | 100% (7/7) | 100% (7/7) |
| pcc | Mac M2, macOS 27.0 (26A5416b), entitled host | 86% (6/7) | 86% (6/7) | 100% (7/7) |

Graders (on-device, raw): expect-contains 86% · ingredients-shopping-friendly 100% · json-only 100% · language:steps[0] 100% · required 100% · schema 100%
