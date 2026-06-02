"""
tools_reference.py
==================

A pure-Python reference implementation of the gateway's deterministic MCP tools
(mirrors gatekeeper/R/mcp_tools.R + the catch_effort rules in
gatekeeper/R/validate.R). It lets the ADF orchestrator run end-to-end in this
sandbox WITHOUT an R runtime, and doubles as the executable spec the R tools are
checked against.

In production the same tool calls are dispatched to R (see mcp_client.py's
RscriptBackend → gatekeeper/mcp/tool_runner.R); the contract is identical.
"""
from __future__ import annotations
import csv
import os
import re
import unicodedata
import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = os.path.join(ROOT, "gatekeeper", "data", "reference")


def fold(x) -> str:
    x = unicodedata.normalize("NFKD", str(x).lower())
    x = "".join(c for c in x if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", " ", x).strip()


def _read(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


# ---- reference data ---------------------------------------------------------
SPECIES = {r["species_code"]: r for r in _read(os.path.join(REF, "species_ref.csv"))}
REGISTRY = {r["vessel_id"]: r for r in _read(os.path.join(REF, "vessel_registry.csv"))}
THRESH = {r["rule_id"]: float(r["threshold"])
          for r in _read(os.path.join(REF, "compliance_thresholds.csv"))}
EEZ = _read(os.path.join(REF, "eez_bounds.csv"))
LAND = _read(os.path.join(REF, "land_bounds.csv"))
SPECIES_SYN = {fold(r["name"]): r["fao_code"]
               for r in _read(os.path.join(REF, "species_synonyms.csv"))}
FIELD_SYN = {fold(r["synonym"]): r["canonical"]
             for r in _read(os.path.join(REF, "field_synonyms.csv"))}
IUU = _read(os.path.join(REF, "iuu_vessel_list.csv"))
CHARTERS = _read(os.path.join(REF, "vessel_charters.csv"))
_ports = _read(os.path.join(REF, "port_codes.csv"))
PORT_SYN = {}
for r in _ports:
    PORT_SYN[fold(r["name"])] = r["unlocode"]
    for a in r["aliases"].split("|"):
        PORT_SYN[fold(a)] = r["unlocode"]


# ---- MCP tools (deterministic) ----------------------------------------------
def read_local_file_sample(file_path, n=5):
    rows = _read(file_path)
    return {"columns": list(rows[0].keys()) if rows else [], "rows": rows[:n]}


def infer_content_type(columns):
    c = [fold(x) for x in columns]
    def has(*xs): return any(fold(x) in c for x in xs)
    if has("species_group", "interaction_type", "observation_id"):
        cat, why = "observer_bycatch", "non-target interaction columns present"
    elif has("length_cm", "length", "sex", "talla"):
        cat, why = "size_composition", "length/sex measurement columns present"
    elif has("event_seq", "activity_id"):
        cat, why = "em_longline", "event-sequence / activity columns present"
    elif has("fad", "school", "set_type", "sets"):
        cat, why = "purse_seine", "FAD / school / set columns present"
    elif has("hooks", "hk_btwn_flt", "anzuelos") or "effort_unit" in c:
        cat, why = "catch_effort", "hooks / effort columns present (longline logsheet)"
    else:
        cat, why = "unknown", "no decisive columns matched"
    # crude language guess from header synonyms
    langs = [r for k, r in FIELD_SYN.items() if k in c]
    lang = "es" if any(fold(h) in {"fecha", "barco", "especie", "anzuelos"} for h in columns) else "en"
    return {"category": cat, "confidence": 0.2 if cat == "unknown" else 0.85,
            "reason": why, "language": lang}


def map_columns(columns):
    """Archaeologist: messy/multilingual headers -> canonical field names."""
    mapping = {}
    for col in columns:
        key = fold(col)
        if key in FIELD_SYN:
            mapping[col] = FIELD_SYN[key]
    return mapping


def resolve_fao(raw_species_string):
    out = []
    for s in raw_species_string:
        code = SPECIES_SYN.get(fold(s), s)
        prot = SPECIES.get(code, {}).get("is_protected") == "1"
        out.append({"input": s, "fao_code": code,
                    "resolved": code != s, "protected": prot})
    return out


def resolve_port(raw_port_string):
    out = []
    for s in raw_port_string:
        code = PORT_SYN.get(fold(s))
        if code is None and re.match(r"^[A-Z]{5}$", str(s)):
            code = s
        out.append({"input": s, "unlocode": code, "resolved": code is not None})
    return out


def _in_box(lat, lon, b):
    a, B = float(b["lon_min"]), float(b["lon_max"])
    d, e = float(b["lat_min"]), float(b["lat_max"])
    lon_ok = (a <= lon <= B) if a <= B else (lon >= a or lon <= B)
    return d <= lat <= e and lon_ok


def validate_spatial_eez(latitude, longitude):
    on_land = any(_in_box(latitude, longitude, b) for b in LAND)
    zone, code = "High seas / unresolved", "HIGH"
    for b in EEZ:
        if _in_box(latitude, longitude, b):
            zone, code = b["country"], b["code"]; break
    return {"latitude": latitude, "longitude": longitude,
            "computed_zone": zone, "zone_code": code, "is_land": on_land}


def check_iuu_status(identifiers):
    """Match any vessel identifier (id / call sign / IMO / name) against the
    offline WCPFC IUU vessel list. A hit must block ingestion."""
    keys = {fold(x) for x in identifiers if str(x).strip()}
    hits = []
    for r in IUU:
        cand = {fold(r["vessel_id"]), fold(r["call_sign"]), fold(r["imo"]),
                fold(r["vessel_name"])} - {""}
        if keys & cand:
            hits.append({"matched_on": list(keys & cand),
                         "vessel_name": r["vessel_name"], "flag": r["flag"],
                         "reason": r["reason"], "cmm": r["cmm"]})
    return {"is_safe_to_ingest": len(hits) == 0, "iuu_hits": hits}


def charter_status(wcpfc_vid, activity_date):
    """Who legally owns the catch on this date? Chartering state if an active
    charter covers the date, else the flag state."""
    d = str(activity_date)
    for c in CHARTERS:
        if fold(c["wcpfc_vid"]) == fold(wcpfc_vid) and c["start_date"] <= d <= c["end_date"]:
            return {"is_chartered": True, "reporting_country": c["charter_state"],
                    "flag_state": c["flag_state"],
                    "notes": f"catch attributed to chartering state {c['charter_state']} "
                             f"(flag {c['flag_state']})"}
    # fall back to flag state from the registry
    flag = REGISTRY.get(wcpfc_vid, {}).get("flag")
    return {"is_chartered": False, "reporting_country": flag, "flag_state": flag,
            "notes": "standard flag-state attribution"}


def harvest_strategy_insight(rows):
    """Lightweight harvest-strategy view: catch composition + a mixed-fishery /
    juvenile-bigeye flag aligned with the WCPFC LRP (<=20% breach) posture."""
    tot = {"SKJ": 0.0, "YFT": 0.0, "BET": 0.0, "ALB": 0.0}
    for r in rows:
        for sp, col in (("SKJ", "catch_skj_kg"), ("YFT", "catch_yft_kg"),
                        ("BET", "catch_bet_kg"), ("ALB", "catch_alb_kg")):
            tot[sp] += _num(r.get(col)) or 0
    grand = sum(tot.values()) or 1
    bet_share = tot["BET"] / grand
    note = None
    if bet_share > 0.15:
        note = (f"Elevated bigeye share ({bet_share*100:.0f}%) in the mixed "
                "skipjack/bigeye/yellowfin fishery — watch against candidate "
                "Target Reference Points and the 20% LRP breach limit.")
    return {"composition_share": {k: round(v / grand, 3) for k, v in tot.items()},
            "bigeye_share": round(bet_share, 3), "advisory": note}


def query_vessel(vessel_sign):
    r = REGISTRY.get(vessel_sign)
    if not r:
        return {"found": False, "vessel_sign": vessel_sign}
    return {"found": True, "wcpfc_vid": r["vessel_id"], "vessel_name": r["vessel_name"],
            "flag_state": r["flag"], "gear_type": r["gear_code"],
            "max_hold_capacity_mt": float(r["hold_capacity_mt"]),
            "max_speed_kn": float(r["max_speed_kn"])}


# ---- compact catch_effort validator (mirrors validate.R / verify_rules.py) --
def _num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def _iso_date(s):
    try:
        y, m, d = str(s).split("-"); datetime.date(int(y), int(m), int(d)); return True
    except (ValueError, TypeError):
        return False


CE_REQUIRED = ["trip_id", "vessel_id", "gear_code", "set_date", "latitude",
               "longitude", "effort_unit", "effort_amount", "catch_total_kg"]


def validate_catch_effort(rows):
    findings = []
    def add(rid, tier, rule, msg):
        findings.append({"record_id": rid, "tier": tier, "rule": rule,
                         "severity": "warning" if tier == "compliance" else "error",
                         "message": msg})
    seen = {}
    for r in rows:
        rid = r.get("trip_id", "?")
        seen[rid] = seen.get(rid, 0) + 1
        for col in CE_REQUIRED:
            if not str(r.get(col, "")).strip():
                add(rid, "structural", "mandatory_field_missing", f"{col} is missing")
        if str(r.get("vessel_id", "")).strip() and r["vessel_id"] not in REGISTRY:
            add(rid, "structural", "vessel_not_registered", "vessel not in registry")
        if r.get("gear_code") not in ("LL", "PS", "PL"):
            add(rid, "structural", "invalid_code", "gear_code not in {LL,PS,PL}")
        lat, lon = _num(r.get("latitude")), _num(r.get("longitude"))
        if lat is None or lon is None or not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
            add(rid, "structural", "coordinate_out_of_range", "coordinate out of range")
        if not _iso_date(r.get("set_date")):
            add(rid, "structural", "invalid_date", "set_date not ISO yyyy-mm-dd")
        sp_sum = sum(_num(r.get(c)) or 0 for c in
                     ["catch_skj_kg", "catch_yft_kg", "catch_bet_kg", "catch_alb_kg"])
        total = _num(r.get("catch_total_kg"))
        if total is not None and abs(total - sp_sum) > max(1.0, 0.01 * sp_sum):
            add(rid, "logical", "catch_total_mismatch", "total != sum of species (check decimal)")
        eff = _num(r.get("effort_amount"))
        if r.get("effort_unit") == "HOOKS" and eff and eff > 0 and sp_sum / eff > THRESH["MAX_CPUE_KG_PER_HOOK"]:
            add(rid, "logical", "implausible_cpue", "catch-per-hook above ceiling")
        v = REGISTRY.get(r.get("vessel_id"))
        if v and sp_sum / 1000.0 > float(v["hold_capacity_mt"]):
            add(rid, "logical", "exceeds_hold_capacity", "catch exceeds vessel hold capacity")
        if r.get("effort_unit") == "HOOKS" and eff and eff > THRESH["MAX_HOOKS_PER_SET"]:
            add(rid, "compliance", "effort_over_guideline", "hooks per set over guideline")
    for rid, n in seen.items():
        if n > 1:
            add(rid, "logical", "duplicate_logsheet", "trip_id duplicated in submission")
    return findings


def submission_status(findings, n_rows):
    n_err = sum(1 for f in findings if f["severity"] == "error")
    n_warn = sum(1 for f in findings if f["severity"] == "warning")
    flagged = len({f["record_id"] for f in findings})
    return {"n_rows": n_rows, "n_error": n_err, "n_warning": n_warn,
            "flagged_rows": flagged, "clean_rows": n_rows - flagged,
            "can_forward": n_err == 0}
