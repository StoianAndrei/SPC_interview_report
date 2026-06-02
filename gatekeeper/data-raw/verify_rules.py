#!/usr/bin/env python3
"""
verify_rules.py
===============

A reference implementation of the gatekeeper's validation rules, used to PROVE
the rule design is correct: it must flag every record listed in the
ground-truth manifest (samples/injected_issues.csv) and should not raise a storm
of false positives on the clean records.

This Python oracle is the executable spec for the R engine in gatekeeper/R/*.R
(which cannot run in this sandbox). Keep the two in sync.

Run:  python3 gatekeeper/data-raw/verify_rules.py
"""
import csv
import math
import os
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.normpath(os.path.join(HERE, "..", "data", "reference"))
SMP = os.path.normpath(os.path.join(HERE, "..", "data", "samples"))


def read(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


species = {r["species_code"]: r for r in read(f"{REF}/species_ref.csv")}
registry = {r["vessel_id"]: r for r in read(f"{REF}/vessel_registry.csv")}
thr = {r["rule_id"]: float(r["threshold"]) for r in read(f"{REF}/compliance_thresholds.csv")}
land = read(f"{REF}/land_bounds.csv")

ce = read(f"{SMP}/catch_effort_sample.csv")
sc = read(f"{SMP}/size_composition_sample.csv")
ob = read(f"{SMP}/observer_bycatch_sample.csv")
em = read(f"{SMP}/em_longline_sample.csv")
hist = read(f"{SMP}/tufman2_history.csv")
manifest = read(f"{SMP}/injected_issues.csv")

findings = []   # (category, record_id, tier, rule)


def add(cat, rid, tier, rule):
    findings.append((cat, rid, tier, rule))


GEARS = {"LL", "PS", "PL"}
EFFORT_UNITS = {"HOOKS", "SETS", "DAYS"}
SEX = {"M", "F", "U"}
GROUPS = {"tuna", "shark", "turtle", "seabird", "mammal", "billfish", "other"}


def is_blank(v):
    return v is None or str(v).strip() == ""


def to_num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def is_iso_date(v):
    p = str(v).split("-")
    if len(p) != 3:
        return False
    try:
        y, m, d = int(p[0]), int(p[1]), int(p[2])
        import datetime
        datetime.date(y, m, d)
        return True
    except ValueError:
        return False


def in_box(lat, lon, b):
    lon_ok = (float(b["lon_min"]) <= lon <= float(b["lon_max"])
              if float(b["lon_min"]) <= float(b["lon_max"])
              else lon >= float(b["lon_min"]) or lon <= float(b["lon_max"]))
    return float(b["lat_min"]) <= lat <= float(b["lat_max"]) and lon_ok


def haversine_nm(a, b, c, d):
    R = 3440.065
    p1, p2 = math.radians(a), math.radians(c)
    dphi, dl = math.radians(c - a), math.radians(d - b)
    h = math.sin(dphi/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return R * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h))


# --------------------------------------------------------------------------
# Catch & Effort
# --------------------------------------------------------------------------
CE_REQUIRED = ["trip_id", "vessel_id", "flag", "gear_code", "set_date",
               "trip_days", "latitude", "longitude", "effort_unit",
               "effort_amount", "target_species", "catch_total_kg"]
seen_trip = defaultdict(int)
hist_keys = {(h["trip_id"], h["vessel_id"]) for h in hist}

for r in ce:
    rid = r["trip_id"]
    # structural
    for col in CE_REQUIRED:
        if is_blank(r.get(col)):
            add("catch_effort", rid, "structural", "mandatory_field_missing"); break
    if not is_blank(r["vessel_id"]) and r["vessel_id"] not in registry:
        add("catch_effort", rid, "structural", "vessel_not_registered")
    if r["gear_code"] not in GEARS:
        add("catch_effort", rid, "structural", "invalid_code")
    lat, lon = to_num(r["latitude"]), to_num(r["longitude"])
    if lat is None or lon is None or not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
        add("catch_effort", rid, "structural", "coordinate_out_of_range")
    if not is_iso_date(r["set_date"]):
        add("catch_effort", rid, "structural", "invalid_date")

    # logical
    td = to_num(r["trip_days"])
    if td is not None and td > thr["MAX_TRIP_DAYS"]:
        add("catch_effort", rid, "logical", "impossible_trip_duration")
    if td is not None and td <= 0:
        add("catch_effort", rid, "logical", "non_positive_duration")
    if lat is not None and lon is not None and -90 <= lat <= 90:
        if any(in_box(lat, lon, b) for b in land):
            add("catch_effort", rid, "logical", "vessel_on_land")
    total = to_num(r["catch_total_kg"]) or 0
    species_sum = sum(to_num(r[c]) or 0 for c in
                      ["catch_skj_kg", "catch_yft_kg", "catch_bet_kg", "catch_alb_kg"])
    if abs(total - species_sum) > max(1.0, 0.01 * species_sum):
        add("catch_effort", rid, "logical", "catch_total_mismatch")
    eff = to_num(r["effort_amount"])
    if r["effort_unit"] == "HOOKS" and eff and eff > 0:
        if (species_sum / eff) > thr["MAX_CPUE_KG_PER_HOOK"]:
            add("catch_effort", rid, "logical", "implausible_cpue")
    v = registry.get(r["vessel_id"])
    if v and species_sum / 1000.0 > float(v["hold_capacity_mt"]):
        add("catch_effort", rid, "logical", "exceeds_hold_capacity")
    seen_trip[rid] += 1
    if (rid, r["vessel_id"]) in hist_keys:
        add("catch_effort", rid, "logical", "duplicate_in_history")

    # compliance
    if r["effort_unit"] == "HOOKS" and eff and eff > thr["MAX_HOOKS_PER_SET"]:
        add("catch_effort", rid, "compliance", "effort_over_guideline")

for rid, n in seen_trip.items():
    if n > 1:
        add("catch_effort", rid, "logical", "duplicate_logsheet")

# overlapping logsheets: a DIFFERENT trip for the same vessel whose date range
# overlaps -- checked against the TUFMAN 2 history mirror
import datetime


def parse_date(s):
    try:
        y, m, d = str(s).split("-"); return datetime.date(int(y), int(m), int(d))
    except (ValueError, TypeError):
        return None


hist_iv = []
for h in hist:
    sd = parse_date(h["set_date"])
    if sd is None:
        continue
    td = int(abs(to_num(h["trip_days"]) or 1))
    hist_iv.append((h["vessel_id"], h["trip_id"], sd, sd + datetime.timedelta(days=td)))
for r in ce:
    sd = parse_date(r["set_date"]); td = to_num(r["trip_days"])
    if sd is None or td is None:
        continue
    end = sd + datetime.timedelta(days=int(abs(td)))
    for hv, ht, hs, he in hist_iv:
        if hv == r["vessel_id"] and ht != r["trip_id"] and sd <= he and hs <= end:
            add("catch_effort", r["trip_id"], "logical", "overlapping_logsheet")
            break

# --------------------------------------------------------------------------
# Size composition
# --------------------------------------------------------------------------
for r in sc:
    rid = r["sample_id"]
    if is_blank(r["length_cm"]):
        add("size_composition", rid, "structural", "mandatory_field_missing")
    if r["sex"] not in SEX:
        add("size_composition", rid, "structural", "invalid_code")
    if r["species_code"] not in species:
        add("size_composition", rid, "structural", "invalid_code")
    L = to_num(r["length_cm"]); W = to_num(r["weight_kg"])
    sp = species.get(r["species_code"])
    if L is not None and sp and float(sp["lmax_cm"]) > 0 and L > float(sp["lmax_cm"]):
        add("size_composition", rid, "logical", "length_over_lmax")
    if (L and W and sp and to_num(sp["lw_a"]) and float(sp["lw_a"]) > 0):
        pred = float(sp["lw_a"]) * (L ** float(sp["lw_b"]))
        if pred > 0 and abs(W - pred) / pred > thr["WEIGHT_AT_LENGTH_TOL"]:
            add("size_composition", rid, "logical", "weight_at_length")

# --------------------------------------------------------------------------
# Observer / bycatch
# --------------------------------------------------------------------------
shark_by_trip = defaultdict(int)
for r in ob:
    rid = r["observation_id"]
    if r["species_code"] not in species:
        add("observer_bycatch", rid, "structural", "invalid_code")
    cnt = to_num(r["count"])
    if cnt is not None and cnt < 0:
        add("observer_bycatch", rid, "logical", "negative_count")
    sp = species.get(r["species_code"])
    if sp and sp["is_protected"] == "1":
        add("observer_bycatch", rid, "compliance", "protected_species_interaction")
    if sp and sp["species_group"] == "shark" and cnt and cnt > 0:
        shark_by_trip[r["trip_id"]] += int(cnt)

hooks_by_trip = defaultdict(float)
for r in ce:
    if r["effort_unit"] == "HOOKS":
        hooks_by_trip[r["trip_id"]] += to_num(r["effort_amount"]) or 0
for trip, sharks in shark_by_trip.items():
    hooks = hooks_by_trip.get(trip, 0)
    if hooks > 0 and (sharks / hooks * 1000.0) > thr["MAX_SHARK_BYCATCH_RATE"]:
        add("observer_bycatch", trip, "compliance", "shark_bycatch_over_threshold")

# --------------------------------------------------------------------------
# EM longline -- excessive speed between consecutive events
# --------------------------------------------------------------------------
by_trip = defaultdict(list)
for r in em:
    by_trip[r["trip_id"]].append(r)
for trip, rows in by_trip.items():
    rows.sort(key=lambda x: int(x["event_seq"]))
    vmax = float(registry[rows[0]["vessel_id"]]["max_speed_kn"]) if rows[0]["vessel_id"] in registry else 20
    for a, b in zip(rows, rows[1:]):
        import datetime
        t1 = datetime.datetime.fromisoformat(a["event_time"].replace("Z", "+00:00"))
        t2 = datetime.datetime.fromisoformat(b["event_time"].replace("Z", "+00:00"))
        hrs = abs((t2 - t1).total_seconds()) / 3600.0
        if hrs <= 0:
            continue
        nm = haversine_nm(float(a["latitude"]), float(a["longitude"]),
                          float(b["latitude"]), float(b["longitude"]))
        if nm / hrs > vmax:
            add("em_longline", trip, "logical", "excessive_speed")
            break

# multiple in-port: two In-Port (activity_id=6) events too far apart to be the
# same docking event
inport = defaultdict(list)
for r in em:
    if str(r.get("activity_id")) == "6":
        inport[r["trip_id"]].append((float(r["latitude"]), float(r["longitude"])))
for trip, pts in inport.items():
    conflict = any(haversine_nm(pts[i][0], pts[i][1], pts[k][0], pts[k][1]) > 50
                   for i in range(len(pts)) for k in range(i + 1, len(pts)))
    if conflict:
        add("em_longline", trip, "logical", "multiple_in_port")

# ==========================================================================
# Compare findings against the manifest
# ==========================================================================
found = {(c, r, t, rule) for c, r, t, rule in findings}
print(f"Findings raised: {len(findings)}  (unique: {len(found)})")

missed = []
for m in manifest:
    key = (m["category"], m["record_id"], m["tier"], m["rule"])
    if key not in found:
        missed.append(key)

print(f"Manifest planted issues: {len(manifest)}")
print(f"Caught: {len(manifest) - len(missed)} / {len(manifest)}")
if missed:
    print("MISSED:")
    for k in missed:
        print("   ", k)
else:
    print("ALL planted anomalies were caught by the rule design. ✅")

# Rough false-positive gauge: flagged records not in the manifest.
manifest_records = {(m["category"], m["record_id"]) for m in manifest}
extra = {(c, r) for c, r, *_ in found} - manifest_records
print(f"\nRecords flagged that were NOT planted (review): {len(extra)}")
for c, r in sorted(extra)[:12]:
    rules = sorted({rule for cc, rr, t, rule in found if cc == c and rr == r})
    print(f"   {c}/{r}: {rules}")
