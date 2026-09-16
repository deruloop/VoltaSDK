# Capability map

Generated 2026-09-16 17:57. Pass rate = passed / scored; scored excludes infrastructure failures (unsupported language, unavailability, rate limits), which show as availability.

## Example: city facts as JSON (`example.city-facts`, schema v1)

| Tier | Host | raw | structured |
|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 100% (5/5) | 100% (5/5) |

Graders (on-device, raw): expect-fields 100% · forbidden-patterns:note 100% · json-only 100% · language:note 100% · required 100% · schema 100%

## Example: find one recipe inside ~12k characters of others (`example.long-context-12k`, schema v1)

| Tier | Host | raw | structured |
|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 0% (0/7) | 100% (7/7) |

Graders (on-device, raw): expect-contains 0% · json-only 100% · required 100% · schema 0%

## Example: find one recipe inside ~16k characters of others (`example.long-context-16k`, schema v1)

| Tier | Host | raw | structured |
|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 0% (0/0) · avail 0% | 0% (0/0) · avail 0% |

## Example: find one recipe inside ~2k characters of others (`example.long-context-2k`, schema v1)

| Tier | Host | raw | structured |
|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 71% (5/7) | 100% (7/7) |

Graders (on-device, raw): expect-contains 71% · json-only 86% · required 86% · schema 71%

## Example: find one recipe inside ~4k characters of others (`example.long-context-4k`, schema v1)

| Tier | Host | raw | structured |
|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 14% (1/7) | 100% (7/7) |

Graders (on-device, raw): expect-contains 14% · json-only 100% · required 100% · schema 14%

## Example: find one recipe inside ~8k characters of others (`example.long-context-8k`, schema v1)

| Tier | Host | raw | structured |
|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 14% (1/7) | 100% (7/7) |

Graders (on-device, raw): expect-contains 14% · json-only 100% · required 100% · schema 14%

## Example: packing list kept across turns (`example.packing-list`, schema v1)

| Tier | Host | raw | structured |
|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 100% (3/3) | 100% (8/8) |
| on-device → pcc | Mac M2, macOS 27.0 (26A5416b), entitled host | — | 100% (8/8) |
| pcc | Mac M2, macOS 27.0 (26A5416b), entitled host | — | 100% (8/8) |
| pcc → on-device | Mac M2, macOS 27.0 (26A5416b), entitled host | — | 88% (7/8) |

Graders (on-device, raw): expect-contains 100% · json-only 100% · retention 100% · schema 100%
