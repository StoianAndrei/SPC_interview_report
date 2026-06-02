"""
test_adf.py  --  prove the local ADF pipeline works end to end.

    python3 adf/test_adf.py     (or: pytest adf/test_adf.py)

Runs the orchestrator over the messy Spanish longline file and asserts the
multi-agent outcomes: content-type + language detection, multilingual column
mapping, species resolution, EEZ resolution, and that the planted data problems
are caught and the submission is correctly HELD.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from orchestrator import ADFOrchestrator

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLE = os.path.join(ROOT, "gatekeeper", "data", "samples", "messy_spanish_ll.csv")


def run():
    res = ADFOrchestrator(verbose=False).handle_file(SAMPLE)
    checks = []

    def chk(name, cond):
        checks.append((name, bool(cond)))

    chk("detected longline catch_effort", res["content_type"]["category"] == "catch_effort")
    chk("detected Spanish language", res["content_type"]["language"] == "es")
    m = res["mapping"]["mapping"]
    chk("mapped Fecha→set_date", m.get("Fecha") == "set_date")
    chk("mapped Barco→vessel_id", m.get("Barco") == "vessel_id")
    chk("mapped Anzuelos→effort_amount", m.get("Anzuelos") == "effort_amount")
    chk("mapped Peso_Total_KG→catch_total_kg", m.get("Peso_Total_KG") == "catch_total_kg")
    faos = {s["input"]: s["fao_code"] for s in res["species"]}
    chk("Atún ojo grande→BET", faos.get("Atún ojo grande") == "BET")
    chk("Listado→SKJ", faos.get("Listado") == "SKJ")
    chk("EEZ resolves to Nauru for T-ES-001", res["eez_zones"].get("T-ES-001") == "Nauru")
    rules = {f["rule"] for f in res["findings"]}
    chk("catches coordinate_out_of_range", "coordinate_out_of_range" in rules)
    chk("catches exceeds_hold_capacity", "exceeds_hold_capacity" in rules)
    chk("catches vessel_not_registered", "vessel_not_registered" in rules)
    chk("submission HELD (not forwarded)", res["decision"] == "HELD_FOR_REVIEW")

    passed = sum(1 for _, ok in checks if ok)
    for name, ok in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    print(f"\n{passed}/{len(checks)} checks passed.")
    return passed == len(checks)


if __name__ == "__main__":
    sys.exit(0 if run() else 1)
