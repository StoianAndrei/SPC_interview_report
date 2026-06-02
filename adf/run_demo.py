#!/usr/bin/env python3
"""
run_demo.py  --  drive the ADF orchestrator over a messy submission.

    python3 adf/run_demo.py [path/to/file.csv]

Defaults to the bundled messy multilingual (Spanish) longline logsheet, showing
the full local pipeline: discover → map → standardise → enrich → validate →
decide, and the plain-language flags a data officer would see.
"""
import os
import sys
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from orchestrator import ADFOrchestrator

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT = os.path.join(ROOT, "gatekeeper", "data", "samples", "messy_spanish_ll.csv")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    print("=" * 70)
    print(" Edge Fisheries Gateway — local ADF orchestration (offline)")
    print(f" File: {os.path.relpath(path, ROOT)}")
    print("=" * 70)
    res = ADFOrchestrator().handle_file(path)

    print("\n--- Result ---------------------------------------------------------")
    print(f"Decision        : {res['decision']}")
    s = res["status"]
    print(f"Rows            : {s['n_rows']}  (clean {s['clean_rows']}, "
          f"flagged {s['flagged_rows']})")
    print(f"Errors/Warnings : {s['n_error']} / {s['n_warning']}")
    if res["protected_species"]:
        print(f"Protected species seen: {res['protected_species']}")

    print("\nPlain-language flags for the data officer:")
    if not res["friendly_flags"]:
        print("  (none — submission is clean)")
    for f in res["friendly_flags"]:
        print(f"  • [{f['severity'].upper()}] {f['record']}: {f['explanation']}")

    print("\nEEZ zones per trip:")
    for trip, zone in res["eez_zones"].items():
        print(f"  {trip}: {zone}")

    print("\n(Full machine-readable result available as JSON.)")
    if "--json" in sys.argv:
        print(json.dumps({k: v for k, v in res.items()
                          if k != "standardised_rows"}, indent=2, default=str))


if __name__ == "__main__":
    main()
