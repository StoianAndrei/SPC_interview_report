#!/usr/bin/env python3
"""
generate_gatekeeper_data.py
===========================

Builds everything the WCPFC / TUFMAN 2 submission-gatekeeper Shiny app needs to
run offline:

  reference/   canonical lookups the validators check against
               (species, vessel registry incl. hold capacity, compliance
               thresholds, EEZ + land boxes)
  templates/   the standardized CSV templates (the WCPFC "flat-file path")
  samples/     example country submissions for all three data categories, with
               a controlled set of PLANTED anomalies so every validation rule
               visibly fires in a demo
  samples/injected_issues.csv  the ground-truth manifest of what we planted

These are SYNTHETIC and clearly labelled. The real gateway would ingest the
WCPFC Public Domain Aggregated Catch & Effort + BDEP bycatch data and the
standardized SciData JSON/CSV submissions, then conditionally forward clean
records to TUFMAN 2's JSON API. This fixture lets the validation engine and
dashboard be built and demonstrated without network access.

Aligned (by category and field intent) to the WCPFC Scientific Data
requirements: Catch & Effort, Size composition, and Observer/bycatch data.

Run:  python3 gatekeeper/data-raw/generate_gatekeeper_data.py
"""
import csv
import os
import random

random.seed(20260601)

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.normpath(os.path.join(HERE, "..", "data", "reference"))
TPL = os.path.normpath(os.path.join(HERE, "..", "data", "templates"))
SMP = os.path.normpath(os.path.join(HERE, "..", "data", "samples"))
for d in (REF, TPL, SMP):
    os.makedirs(d, exist_ok=True)


def write_csv(path, rows, fields):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fields})
    print(f"  {len(rows):>4} rows -> {os.path.relpath(path)}")


def write_header_only(path, fields):
    with open(path, "w", newline="") as f:
        csv.DictWriter(f, fieldnames=fields).writeheader()
    print(f"  template -> {os.path.relpath(path)}")


# ===========================================================================
# Canonical column sets -- the shared contract with gatekeeper/R/schemas.R.
# ===========================================================================
COLS = {
    "catch_effort": [
        "trip_id", "vessel_id", "flag", "gear_code", "set_date", "trip_days",
        "latitude", "longitude", "effort_unit", "effort_amount",
        "target_species", "catch_skj_kg", "catch_yft_kg", "catch_bet_kg",
        "catch_alb_kg", "catch_total_kg",
    ],
    "em_longline": [
        "trip_id", "vessel_id", "event_seq", "event_time", "event_type",
        "latitude", "longitude",
    ],
    "size_composition": [
        "sample_id", "trip_id", "species_code", "length_cm", "weight_kg",
        "sex", "measure_date",
    ],
    "observer_bycatch": [
        "observation_id", "trip_id", "set_date", "latitude", "longitude",
        "species_code", "species_group", "interaction_type", "condition",
        "count",
    ],
}

# ===========================================================================
# Reference data
# ===========================================================================
SPECIES = [
    # code, common,             group,    lmax, lw_a,    lw_b,  protected
    ("SKJ", "Skipjack tuna",    "tuna",    110, 5.5e-6, 3.34, 0),
    ("YFT", "Yellowfin tuna",   "tuna",    200, 2.5e-5, 2.98, 0),
    ("BET", "Bigeye tuna",      "tuna",    200, 3.7e-5, 2.95, 0),
    ("ALB", "Albacore tuna",    "tuna",    120, 1.3e-5, 3.10, 0),
    ("BSH", "Blue shark",       "shark",   400, 3.2e-6, 3.13, 0),
    ("OCS", "Oceanic whitetip", "shark",   350, 4.0e-6, 3.10, 1),
    ("FAL", "Silky shark",      "shark",   330, 4.5e-6, 3.08, 1),
    ("TTX", "Sea turtle",       "turtle",  120, 0.0,    0.0,  1),
    ("SBX", "Seabird",          "seabird",  90, 0.0,    0.0,  1),
    ("MAM", "Marine mammal",    "mammal",  300, 0.0,    0.0,  1),
]
write_csv(os.path.join(REF, "species_ref.csv"),
          [dict(species_code=c, common_name=n, species_group=g, lmax_cm=l,
                lw_a=a, lw_b=b, is_protected=p)
           for c, n, g, l, a, b, p in SPECIES],
          ["species_code", "common_name", "species_group", "lmax_cm",
           "lw_a", "lw_b", "is_protected"])

GEARS = ["LL", "PS", "PL"]   # longline, purse seine, pole-and-line
# Member flags (the multi-tenant "country" dimension; ISO3-style WCPFC codes).
FLAGS = ["FJI", "PNG", "KIR", "FSM", "MHL", "SLB", "TUV", "NRU"]
# Typical hold capacity (metric tonnes) by gear -- powers the
# "catch exceeds vessel hold capacity / decimal-point" check.
HOLD = {"LL": (40, 160), "PS": (600, 1600), "PL": (80, 300)}
# Maximum structural speed (knots) by gear -- powers the excessive-speed check.
SPEED = {"LL": 12, "PS": 18, "PL": 14}

VESSELS = []
for i in range(1, 41):
    gear = random.choice(GEARS)
    lo, hi = HOLD[gear]
    VESSELS.append(dict(
        vessel_id=f"WCPFC-{1000 + i}",
        vessel_name=f"Vessel {i:02d}",
        flag=random.choice(FLAGS),
        gear_code=gear,
        hold_capacity_mt=random.randint(lo, hi),
        max_speed_kn=SPEED[gear],
        status="active",
    ))
# the vessel used by the TUFMAN 2 LL JSON sample (so the clean payload passes)
VESSELS.append(dict(vessel_id="WCPFC-11774", vessel_name="Mini Set",
                    flag="FSM", gear_code="LL", hold_capacity_mt=120,
                    max_speed_kn=SPEED["LL"], status="active"))
write_csv(os.path.join(REF, "vessel_registry.csv"), VESSELS,
          ["vessel_id", "vessel_name", "flag", "gear_code",
           "hold_capacity_mt", "max_speed_kn", "status"])
REG = {v["vessel_id"]: v for v in VESSELS}

THRESHOLDS = [
    dict(rule_id="MAX_TRIP_DAYS", description="Maximum plausible trip duration",
         threshold=120, unit="days"),
    dict(rule_id="MAX_HOOKS_PER_SET",
         description="Max longline hooks per set (effort guideline)",
         threshold=3500, unit="hooks"),
    dict(rule_id="MAX_SETS_PER_DAY",
         description="Max purse-seine sets per day", threshold=3, unit="sets"),
    dict(rule_id="MAX_SHARK_BYCATCH_RATE",
         description="Max shark interactions per 1000 hooks",
         threshold=8.0, unit="per_1000_hooks"),
    dict(rule_id="MAX_CPUE_KG_PER_HOOK",
         description="Implausible longline catch-per-hook ceiling",
         threshold=12.0, unit="kg_per_hook"),
    dict(rule_id="WEIGHT_AT_LENGTH_TOL",
         description="Allowed deviation from length-weight curve",
         threshold=0.45, unit="fraction"),
]
write_csv(os.path.join(REF, "compliance_thresholds.csv"), THRESHOLDS,
          ["rule_id", "description", "threshold", "unit"])

# Rough EEZ boxes (lon in -180..180) used to flag points outside any WCPO EEZ.
EEZ = [
    ("PNG", "Papua New Guinea", 139, 160, -12, 1),
    ("SLB", "Solomon Islands", 155, 170, -13, -5),
    ("FSM", "Micronesia", 137, 164, 0, 14),
    ("KIR", "Kiribati", 169, -150, -12, 8),   # spans the date line
    ("MHL", "Marshall Islands", 160, 175, 4, 15),
    ("FJI", "Fiji", 174, -178, -23, -12),
    ("TUV", "Tuvalu", 175, 180, -11, -5),
    ("NRU", "Nauru", 165, 168, -1, 0.5),
    ("HIGH", "High seas pocket", 160, 180, -10, 10),
]
write_csv(os.path.join(REF, "eez_bounds.csv"),
          [dict(code=c, country=n, lon_min=a, lon_max=b, lat_min=d, lat_max=e)
           for c, n, a, b, d, e in EEZ],
          ["code", "country", "lon_min", "lon_max", "lat_min", "lat_max"])

# Major landmasses -- a point inside one of these boxes is almost certainly a
# keying error for a pelagic vessel (the "longliner in a landmass" check).
LAND = [
    ("Australia", 113, 153, -39, -11),
    ("New Guinea", 140, 150, -9, -3),
    ("Asia mainland", 95, 122, 5, 35),
]
write_csv(os.path.join(REF, "land_bounds.csv"),
          [dict(name=n, lon_min=a, lon_max=b, lat_min=d, lat_max=e)
           for n, a, b, d, e in LAND],
          ["name", "lon_min", "lon_max", "lat_min", "lat_max"])

# ===========================================================================
# Templates (empty, header-only -- the standardized flat-file path)
# ===========================================================================
for name, cols in COLS.items():
    write_header_only(os.path.join(TPL, f"{name}_template.csv"), cols)

# ===========================================================================
# Sample submission with PLANTED anomalies
# ===========================================================================
issues = []


def flag(category, ref_id, tier, rule, detail):
    issues.append(dict(category=category, record_id=ref_id, tier=tier,
                       rule=rule, detail=detail))


SPECIES_TUNA = ["SKJ", "YFT", "BET", "ALB"]


def _on_land(lat, lon):
    for _, a, b, d, e in LAND:
        if d <= lat <= e and a <= lon <= b:
            return True
    return False


def rand_point():
    """A plausible WCPO fishing location that is genuinely at sea."""
    for _ in range(50):
        lon = random.uniform(135, 210)
        if lon > 180:
            lon -= 360
        lat = random.uniform(-20, 12)
        if not _on_land(lat, lon):
            return round(lat, 3), round(lon, 3)
    return round(lat, 3), round(lon, 3)


# ---- Catch & Effort --------------------------------------------------------
ce = []
for i in range(1, 121):
    v = random.choice(VESSELS)
    gear = v["gear_code"]
    lat, lon = rand_point()
    mon, day = random.randint(1, 12), random.randint(1, 28)
    unit = {"LL": "HOOKS", "PS": "SETS", "PL": "DAYS"}[gear]
    eff = (random.randint(1200, 3200) if unit == "HOOKS"
           else random.randint(1, 3) if unit == "SETS" else random.randint(1, 5))
    # base catch kept comfortably under hold capacity
    cap_kg = v["hold_capacity_mt"] * 1000
    base = min(cap_kg * random.uniform(0.2, 0.7),
               eff * (3.0 if unit == "HOOKS" else 9000 if unit == "SETS" else 1500))
    skj = int(base * random.uniform(0.4, 0.7))
    yft = int(base * random.uniform(0.1, 0.3))
    bet = int(base * random.uniform(0.02, 0.08))
    alb = int(base * random.uniform(0.0, 0.06))
    ce.append(dict(
        trip_id=f"T2024-{i:03d}", vessel_id=v["vessel_id"], flag=v["flag"],
        gear_code=gear, set_date=f"2024-{mon:02d}-{day:02d}",
        trip_days=random.randint(5, 35), latitude=lat, longitude=lon,
        effort_unit=unit, effort_amount=eff,
        target_species=random.choice(SPECIES_TUNA),
        catch_skj_kg=skj, catch_yft_kg=yft, catch_bet_kg=bet, catch_alb_kg=alb,
        catch_total_kg=skj + yft + bet + alb,   # should equal the species sum
    ))

# make trip[0] a longline w/ defined hooks (the heavy shark-bycatch + EM-speed trip)
ce[0]["gear_code"] = "LL"; ce[0]["effort_unit"] = "HOOKS"; ce[0]["effort_amount"] = 1500

# planted anomalies (record_id = trip_id)
ce[5]["vessel_id"] = ""
flag("catch_effort", ce[5]["trip_id"], "structural", "mandatory_field_missing", "vessel_id is blank")
ce[10]["vessel_id"] = "WCPFC-9999"
flag("catch_effort", ce[10]["trip_id"], "structural", "vessel_not_registered", "vessel_id absent from registry")
ce[15]["gear_code"] = "XX"
flag("catch_effort", ce[15]["trip_id"], "structural", "invalid_code", "gear_code not in {LL,PS,PL}")
ce[20]["latitude"] = 95.0
flag("catch_effort", ce[20]["trip_id"], "structural", "coordinate_out_of_range", "latitude 95 > 90")
ce[25]["set_date"] = "31/02/2024"
flag("catch_effort", ce[25]["trip_id"], "structural", "invalid_date", "set_date not ISO / impossible date")
ce[30]["trip_days"] = 400
flag("catch_effort", ce[30]["trip_id"], "logical", "impossible_trip_duration", "trip_days exceeds MAX_TRIP_DAYS")
ce[31]["trip_days"] = -3
flag("catch_effort", ce[31]["trip_id"], "logical", "non_positive_duration", "trip_days <= 0")
ce[35]["latitude"] = -25.0; ce[35]["longitude"] = 134.0
flag("catch_effort", ce[35]["trip_id"], "logical", "vessel_on_land", "coordinate inside Australian landmass")
# implausible CPUE: force a longline row with tiny effort, huge catch
ce[40]["gear_code"] = "LL"; ce[40]["effort_unit"] = "HOOKS"
ce[40]["effort_amount"] = 5; ce[40]["catch_skj_kg"] = 90000
flag("catch_effort", ce[40]["trip_id"], "logical", "implausible_cpue", "catch-per-hook above ceiling")
# catch exceeds vessel hold capacity (the decimal-point example)
ce[50]["catch_yft_kg"] = REG.get(ce[50]["vessel_id"], {"hold_capacity_mt": 100})["hold_capacity_mt"] * 1000 * 6
flag("catch_effort", ce[50]["trip_id"], "logical", "exceeds_hold_capacity", "total catch exceeds vessel hold capacity")
# effort over compliance guideline (hooks/set)
ce[45]["gear_code"] = "LL"; ce[45]["effort_unit"] = "HOOKS"; ce[45]["effort_amount"] = 9000
flag("catch_effort", ce[45]["trip_id"], "compliance", "effort_over_guideline", "hooks per set exceeds MAX_HOOKS_PER_SET")
# catch_total_kg does not equal the sum of species weights (decimal-point typo)
ce[55]["catch_total_kg"] = ce[55]["catch_total_kg"] * 10
flag("catch_effort", ce[55]["trip_id"], "logical", "catch_total_mismatch", "catch_total_kg != sum of species weights")
# duplicate logsheet already present in TUFMAN 2 history (same trip_id + vessel)
flag("catch_effort", ce[1]["trip_id"], "logical", "duplicate_in_history", "trip_id already recorded in TUFMAN 2")

# within-submission duplicate logsheet (same trip_id appears twice)
dup = dict(ce[60])
ce.append(dup)
flag("catch_effort", ce[60]["trip_id"], "logical", "duplicate_logsheet", "trip_id duplicated within submission")

write_csv(os.path.join(SMP, "catch_effort_sample.csv"), ce, COLS["catch_effort"])

# ---- TUFMAN 2 historical trips (for duplicate / overlap detection) ---------
history = []
for h in range(1, 51):
    v = random.choice(VESSELS)
    history.append(dict(trip_id=f"H2023-{h:03d}", vessel_id=v["vessel_id"],
                        set_date=f"2023-{random.randint(1,12):02d}-{random.randint(1,28):02d}",
                        trip_days=random.randint(5, 35)))
# the duplicate-in-history plant: trip already on file for that vessel
history.append(dict(trip_id=ce[1]["trip_id"], vessel_id=ce[1]["vessel_id"],
                    set_date=ce[1]["set_date"], trip_days=ce[1]["trip_days"]))
write_csv(os.path.join(SMP, "tufman2_history.csv"), history,
          ["trip_id", "vessel_id", "set_date", "trip_days"])

# ---- Longline E-Monitoring event stream (for the excessive-speed demo) -----
import math


def haversine_nm(lat1, lon1, lat2, lon2):
    R = 3440.065  # nautical miles
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = (math.sin(dphi / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2)
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


em = []
ll_trips = [r for r in ce if r["gear_code"] == "LL"][:14]
for tr in ll_trips:
    lat, lon = float(tr["latitude"]), float(tr["longitude"])
    if abs(lat) > 90:        # skip the planted out-of-range coordinate
        continue
    t = 0
    for seq in range(1, 7):
        # ~8 knots: move a small distance each 3-hour step
        lat += random.uniform(-0.2, 0.2)
        lon += random.uniform(0.1, 0.4)
        t += 3
        em.append(dict(trip_id=tr["trip_id"], vessel_id=tr["vessel_id"],
                       event_seq=seq,
                       event_time=f"{tr['set_date']}T{t % 24:02d}:00:00Z",
                       event_type=random.choice(["SET", "HAUL", "POSITION"]),
                       latitude=round(lat, 3), longitude=round(lon, 3)))

# plant an excessive-speed segment: a 6-degree jump (~360 nm) in one 3h step
speed_trip = ll_trips[0]["trip_id"]
rows_for_trip = [r for r in em if r["trip_id"] == speed_trip]
if rows_for_trip:
    j = rows_for_trip[-1]
    j["latitude"] = round(j["latitude"] + 6.0, 3)
    j["longitude"] = round(j["longitude"] + 4.0, 3)
flag("em_longline", speed_trip, "logical", "excessive_speed",
     "implied vessel speed between events exceeds max structural knots")

write_csv(os.path.join(SMP, "em_longline_sample.csv"), em, COLS["em_longline"])

# ---- Size Composition (deliberately omits Q3 -> completeness gap) ----------
sc = []
sid = 0
LW = {c: (a, b, lmax) for c, _, _, lmax, a, b, _ in SPECIES}


def _month(s):
    s = str(s)
    return int(s.split("-")[1]) if s.count("-") >= 2 else -1


for tr in ce[:90]:
    if _month(tr["set_date"]) in (7, 8, 9):
        continue
    for _ in range(random.randint(2, 5)):
        sid += 1
        sp = random.choice(SPECIES_TUNA)
        a, b, lmax = LW[sp]
        length = round(random.uniform(35, min(lmax, 160)), 1)
        weight = round(a * (length ** b) * random.uniform(0.9, 1.1), 2)
        sc.append(dict(sample_id=f"S{sid:04d}", trip_id=tr["trip_id"],
                       species_code=sp, length_cm=length, weight_kg=weight,
                       sex=random.choice(["M", "F", "U"]),
                       measure_date=tr["set_date"]))

sc[3]["length_cm"] = 320.0
flag("size_composition", sc[3]["sample_id"], "logical", "length_over_lmax", "length exceeds species Lmax")
sc[7]["weight_kg"] = 0.2
flag("size_composition", sc[7]["sample_id"], "logical", "weight_at_length", "weight implausible for length")
sc[11]["sex"] = "Q"
flag("size_composition", sc[11]["sample_id"], "structural", "invalid_code", "sex not in {M,F,U}")
sc[14]["length_cm"] = ""
flag("size_composition", sc[14]["sample_id"], "structural", "mandatory_field_missing", "length_cm is blank")

write_csv(os.path.join(SMP, "size_composition_sample.csv"), sc, COLS["size_composition"])

# ---- Observer & Bycatch ----------------------------------------------------
ob = []
oid = 0
GROUPS = {"BSH": "shark", "OCS": "shark", "FAL": "shark",
          "TTX": "turtle", "SBX": "seabird", "MAM": "mammal"}
# bias the pool to non-protected blue shark so planted protected interactions
# (and the heavy-bycatch trip) stand out rather than being lost in the noise
POOL = ["BSH"] * 8 + ["OCS", "FAL", "TTX", "SBX", "MAM"]
for tr in ce[:70]:
    for _ in range(random.randint(0, 3)):
        oid += 1
        sp = random.choice(POOL)
        ob.append(dict(observation_id=f"O{oid:04d}", trip_id=tr["trip_id"],
                       set_date=tr["set_date"], latitude=tr["latitude"],
                       longitude=tr["longitude"], species_code=sp,
                       species_group=GROUPS[sp],
                       interaction_type=random.choice(["caught", "entangled", "hooked"]),
                       condition=random.choice(["alive", "dead", "released_alive"]),
                       count=random.randint(1, 3)))

ob[2]["species_code"] = "TTX"; ob[2]["species_group"] = "turtle"; ob[2]["condition"] = "dead"
flag("observer_bycatch", ob[2]["observation_id"], "compliance", "protected_species_interaction", "sea turtle interaction (dead)")
heavy_trip = ce[0]["trip_id"]
for _ in range(6):
    oid += 1
    ob.append(dict(observation_id=f"O{oid:04d}", trip_id=heavy_trip,
                   set_date=ce[0]["set_date"], latitude=ce[0]["latitude"],
                   longitude=ce[0]["longitude"], species_code="BSH",
                   species_group="shark", interaction_type="caught",
                   condition="dead", count=4))
flag("observer_bycatch", heavy_trip, "compliance", "shark_bycatch_over_threshold",
     "shark interactions per 1000 hooks exceed MAX_SHARK_BYCATCH_RATE")
ob[5]["species_code"] = "ZZZ"
flag("observer_bycatch", ob[5]["observation_id"], "structural", "invalid_code", "species_code not in reference")
ob[8]["count"] = -2
flag("observer_bycatch", ob[8]["observation_id"], "logical", "negative_count", "count below zero")

write_csv(os.path.join(SMP, "observer_bycatch_sample.csv"), ob, COLS["observer_bycatch"])

write_csv(os.path.join(SMP, "injected_issues.csv"), issues,
          ["category", "record_id", "tier", "rule", "detail"])

# ===========================================================================
# Sanity summary
# ===========================================================================
print("\nPlanted anomalies by tier:")
for tier in ("structural", "logical", "compliance"):
    print(f"  {tier:11s}: {sum(1 for x in issues if x['tier'] == tier)}")
print(f"  TOTAL      : {len(issues)} planted issues across 3 categories")
print(f"\nRecords: catch_effort={len(ce)}, size_composition={len(sc)}, "
      f"observer_bycatch={len(ob)}, em_longline={len(em)}, history={len(history)}")
print(f"Size-composition Q3 records (intentional gap): "
      f"{sum(1 for r in sc if _month(r['measure_date']) in (7, 8, 9))}")
print("Done.")
