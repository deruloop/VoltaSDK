#!/usr/bin/env python3
"""Merge `[evals-entry] {...}` lines from a hosted run's log (the PCC bundle
on the Mac, or the iOS bundle on a device) into the capability map, and
regenerate its Markdown twin.

    xcodebuild test ... 2>&1 | tee run.log
    python3 scripts/evals-merge.py run.log [docs/evals/results/capability-map.json]

Entries replace existing rows with the same (task, tier, mode) key, exactly
as the engine's own upsert does. The Markdown rendering mirrors
CapabilityMap.markdown in Tests/VoltaSDKEvals/Engine/CapabilityMap.swift.
"""
import datetime
import json
import sys

MODE_ORDER = ["raw", "structured", "structured+repair"]


def percent(value):
    return "%.0f%%" % (value * 100)


def markdown(doc):
    generated = doc.get("generatedAt", "")[:16].replace("T", " ")
    text = ("# Capability map\n\nGenerated %s. Pass rate = passed / scored; scored excludes "
            "infrastructure failures (unsupported language, unavailability, rate limits), "
            "which show as availability.\n" % generated)
    tasks = {}
    for entry in doc["entries"]:
        tasks.setdefault(entry["task"], []).append(entry)
    for task in sorted(tasks):
        rows = tasks[task]
        title = rows[0].get("taskTitle", task)
        version = rows[0].get("schemaVersion", "")
        modes = sorted({r["mode"] for r in rows}, key=lambda m: MODE_ORDER.index(m) if m in MODE_ORDER else 99)
        text += "\n## %s (`%s`, schema %s)\n\n" % (title, task, version)
        text += "| Tier | Host | " + " | ".join(modes) + " |\n"
        text += "|---|---|" + "|".join("---" for _ in modes) + "|\n"
        tiers = {}
        for r in rows:
            tiers.setdefault(r["tier"], []).append(r)
        for tier in sorted(tiers):
            tier_rows = tiers[tier]
            host = tier_rows[0].get("host", "")
            label = tier_rows[0].get("tierLabel", tier)
            cells = []
            for mode in modes:
                row = next((r for r in tier_rows if r["mode"] == mode), None)
                if row is None:
                    cells.append("—")
                    continue
                cell = "%s (%d/%d)" % (percent(row["passRate"]), row["passed"], row["scored"])
                if row.get("availabilityRate", 1) < 1:
                    cell += " · avail " + percent(row["availabilityRate"])
                judge = row.get("judge")
                if judge:
                    dims = ", ".join("%s %s" % (k, percent(v)) for k, v in sorted(judge.get("dimensions", {}).items()))
                    cell += " · judge " + dims
                    agreement = judge.get("agreement")
                    if agreement:
                        cell += " (κ %.2f, n=%d)" % (agreement["kappa"], agreement["overlap"])
                cells.append(cell)
            text += "| %s | %s | " % (label, host) + " | ".join(cells) + " |\n"
        raw = next((r for r in rows if r["mode"] == "raw"), rows[0])
        breakdown = " · ".join("%s %s" % (k, percent(v)) for k, v in sorted(raw.get("graders", {}).items()))
        if breakdown:
            text += "\nGraders (%s, %s): %s\n" % (raw["tier"], raw["mode"], breakdown)
    return text


def main():
    log = sys.argv[1]
    target = sys.argv[2] if len(sys.argv) > 2 else "docs/evals/results/capability-map.json"
    entries = []
    for line in open(log, encoding="utf-8", errors="ignore"):
        if "[evals-entry] " in line:
            entries.append(json.loads(line.split("[evals-entry] ", 1)[1]))
    try:
        doc = json.load(open(target))
    except FileNotFoundError:
        doc = {"generatedAt": "", "entries": []}
    for entry in entries:
        key = (entry["task"], entry["tier"], entry["mode"])
        doc["entries"] = [e for e in doc["entries"] if (e["task"], e["tier"], e["mode"]) != key] + [entry]
    doc["entries"].sort(key=lambda e: (e["task"], e["tier"], e["mode"]))
    doc["generatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    json.dump(doc, open(target, "w"), indent=2, sort_keys=True, ensure_ascii=False)
    with open(target.rsplit(".", 1)[0] + ".md", "w") as handle:
        handle.write(markdown(doc))
    print("merged", len(entries), "entries into", target)


if __name__ == "__main__":
    main()
