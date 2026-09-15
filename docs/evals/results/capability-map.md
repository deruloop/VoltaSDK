# Capability map

Generated 2026-09-15 17:10. Pass rate = passed / scored; scored excludes infrastructure failures (unsupported language, unavailability, rate limits), which show as availability.

## Example: city facts as JSON (`example.city-facts`, schema v1)

| Tier | Host | raw | structured |
|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 100% (5/5) | 100% (5/5) |

Graders (on-device, raw): expect-fields 100% · forbidden-patterns:note 100% · json-only 100% · language:note 100% · required 100% · schema 100%

## Example: packing list kept across turns (`example.packing-list`, schema v1)

| Tier | Host | raw | structured |
|---|---|---|---|
| on-device | Mac M2, macOS 27.0 (26A5416b) | 100% (3/3) | 100% (3/3) |

Graders (on-device, raw): expect-contains 100% · json-only 100% · retention 100% · schema 100%
