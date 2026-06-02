#!/usr/bin/env python3
"""
generate_samples.py
===================

Builds the *cached sample* datasets that ship with this pipeline so the whole
thing runs offline (e.g. inside a sandbox where the Pacific Data Hub is not
reachable). These files are SYNTHETIC but calibrated to the real-world shape and
magnitude of Western & Central Pacific Ocean (WCPO) tuna fisheries:

  - Skipjack (SKJ) dominates the catch (~70%), then yellowfin, bigeye, albacore.
  - The Parties to the Nauru Agreement (PNA) waters in the west hold most catch.
  - A warming ocean (rising SST anomaly) is associated with the catch centre of
    gravity drifting EAST during warm/ENSO years.
  - For several small island states, access fees from the tuna fishery are a
    very large share of government revenue.

When the live pipeline runs with network access it pulls the genuine indicator
(Mean sea surface temperature anomaly, plus the fisheries series) from the
Pacific Data Hub .Stat SDMX API; these cached CSVs are the fallback and the
fixture used for development. They are clearly labelled as synthetic in the
data dictionary and sources file so nobody mistakes them for official figures.

Run:  python3 pipeline/data-raw/generate_samples.py
"""

import csv
import math
import os
import random

random.seed(20260601)  # contest opens 1 June 2026 -> reproducible

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.normpath(os.path.join(HERE, "..", "data", "raw"))
META = os.path.normpath(os.path.join(HERE, "..", "data", "meta"))
os.makedirs(RAW, exist_ok=True)
os.makedirs(META, exist_ok=True)

YEARS = list(range(2000, 2024))  # 2000-2023 inclusive

# ---------------------------------------------------------------------------
# Country reference table.
#   lon360  : EEZ-centroid longitude on a 0-360 (eastward-positive) scale so the
#             international date line stops longitudes wrapping; bigger = further
#             east. Used to measure the catch "centre of gravity".
#   pna     : Party to the Nauru Agreement (controls the bulk of the purse-seine
#             skipjack fishery in the west).
#   base    : relative skipjack purse-seine catch weight (calibration only).
#   dep     : how exposed the public budget is to fishing access fees (0-1);
#             small PNA atolls are extremely exposed.
# ---------------------------------------------------------------------------
COUNTRIES = [
    # code  name                       lon360  lat    pna   base  dep
    ("PNG", "Papua New Guinea",        145.0,  -6.3,  True,  1.00, 0.10),
    ("SLB", "Solomon Islands",         160.0,  -9.0,  True,  0.45, 0.18),
    ("FSM", "Micronesia (Fed. States)",158.0,   6.9,  True,  0.55, 0.40),
    ("NRU", "Nauru",                   166.9,  -0.5,  True,  0.10, 0.55),
    ("KIR", "Kiribati",                185.0,   1.4,  True,  0.85, 0.65),
    ("MHL", "Marshall Islands",        171.0,   7.1,  True,  0.40, 0.45),
    ("TUV", "Tuvalu",                  178.7,  -7.5,  True,  0.12, 0.60),
    ("PLW", "Palau",                   134.5,   7.5,  True,  0.06, 0.20),
    ("TKL", "Tokelau",                 188.0,  -9.2,  False, 0.05, 0.50),
    ("FJI", "Fiji",                    178.0, -17.7,  False, 0.18, 0.12),
    ("WSM", "Samoa",                   188.2, -13.8,  False, 0.07, 0.10),
    ("COK", "Cook Islands",            200.2, -21.2,  False, 0.10, 0.22),
    ("PYF", "French Polynesia",        210.5, -17.5,  False, 0.09, 0.08),
]

CODE_NAME = {c[0]: c[1] for c in COUNTRIES}
LON = {c[0]: c[2] for c in COUNTRIES}
LAT = {c[0]: c[3] for c in COUNTRIES}
PNA = {c[0]: c[4] for c in COUNTRIES}
BASE = {c[0]: c[5] for c in COUNTRIES}
DEP = {c[0]: c[6] for c in COUNTRIES}

# A simple multivariate ENSO-like index per year (positive = warm/El Nino,
# which historically pushes the skipjack fishery eastward).
ENSO = {y: 0.0 for y in YEARS}
for y, v in {
    2002: 0.8, 2009: 0.6, 2010: -0.9, 2014: 0.4, 2015: 1.6, 2016: 1.2,
    2018: 0.5, 2019: 0.7, 2020: -0.8, 2021: -1.0, 2022: -0.9, 2023: 0.9,
}.items():
    ENSO[y] = v


def noise(scale):
    return random.gauss(0.0, scale)


# ---------------------------------------------------------------------------
# 1. Mean sea surface temperature anomaly  (THE required SPC indicator)
#    Regional warming trend + per-country offset + ENSO modulation.
# ---------------------------------------------------------------------------
def sst_anomaly():
    rows = []
    for code, name, lon, lat, pna, base, dep in COUNTRIES:
        # equatorial/western-pool sites warm a touch faster
        warm_bias = 0.06 if abs(lat) < 8 else 0.0
        for y in YEARS:
            t = y - 2000
            val = (0.28 + warm_bias) + 0.024 * t + 0.18 * ENSO[y] + noise(0.06)
            rows.append({
                "geo": code,
                "country": name,
                "year": y,
                "indicator": "Mean sea surface temperature anomaly",
                "unit": "degrees Celsius",
                "sst_anomaly_c": round(val, 3),
            })
    return rows


# Annual regional mean SST anomaly (drives the eastward shift below).
def regional_sst(rows):
    out = {}
    for y in YEARS:
        vals = [r["sst_anomaly_c"] for r in rows if r["year"] == y]
        out[y] = sum(vals) / len(vals)
    return out


# ---------------------------------------------------------------------------
# 2. Tuna catch by country / year / species (tonnes)
#    Western base catch, warm years shift effort & catch eastward.
# ---------------------------------------------------------------------------
SPECIES = [
    # code, name,        share, southern_pref (albacore skews south/east)
    ("SKJ", "Skipjack",  0.70, 0.0),
    ("YFT", "Yellowfin", 0.20, 0.0),
    ("BET", "Bigeye",    0.06, 0.0),
    ("ALB", "Albacore",  0.04, 1.0),
]

REGION_TOTAL_2000 = 1_900_000.0  # tonnes, scaled up over time toward ~2.7M


def tuna_catch(reg_sst):
    rows = []
    sst0 = reg_sst[YEARS[0]]
    for y in YEARS:
        t = y - 2000
        # whole-region catch grows with effort/technology over the period
        region_total = REGION_TOTAL_2000 * (1 + 0.018 * t)
        # cumulative warming relative to the first year -> eastward push
        warm = (reg_sst[y] - sst0) + 0.25 * ENSO[y]
        # eastward weight: western lon get lighter, eastern lon get heavier
        weights = {}
        for code in CODE_NAME:
            # centre eastward push on ~175 lon; positive east of it gains
            east_gain = 1.0 + 0.45 * warm * ((LON[code] - 172.0) / 30.0)
            east_gain = max(0.35, east_gain)
            weights[code] = BASE[code] * east_gain
        wsum = sum(weights.values())
        for code in CODE_NAME:
            country_catch = region_total * weights[code] / wsum
            for scode, sname, share, south in SPECIES:
                # albacore concentrates in the cooler south/east EEZs
                s_adj = share * (1.0 + south * (1.0 if LAT[code] < -12 else -0.6))
                val = country_catch * max(0.0, s_adj) * (1 + noise(0.05))
                rows.append({
                    "geo": code,
                    "country": CODE_NAME[code],
                    "year": y,
                    "species_code": scode,
                    "species": sname,
                    "catch_tonnes": int(round(val)),
                })
    return rows


# ---------------------------------------------------------------------------
# 3. Fishing vessels & effort (purse seine + longline + pole-and-line)
#    Active vessels and fishing days scale with catch.
# ---------------------------------------------------------------------------
GEARS = [
    ("PS", "Purse seine",    0.78, 14.0),   # share of catch, tonnes/day proxy
    ("LL", "Longline",       0.16, 2.5),
    ("PL", "Pole-and-line",  0.06, 6.0),
]


def vessels(catch_rows):
    # total catch per country/year
    cc = {}
    for r in catch_rows:
        cc[(r["geo"], r["year"])] = cc.get((r["geo"], r["year"]), 0) + r["catch_tonnes"]
    rows = []
    for (code, y), total in sorted(cc.items()):
        for gcode, gname, gshare, tpd in GEARS:
            g_catch = total * gshare
            fishing_days = g_catch / tpd
            # vessels: ~ fishing days / (days each vessel fishes in this EEZ)
            days_per_vessel = {"PS": 38.0, "LL": 120.0, "PL": 60.0}[gcode]
            n_vessels = max(0, int(round(fishing_days / days_per_vessel * (1 + noise(0.04)))))
            rows.append({
                "geo": code,
                "country": CODE_NAME[code],
                "year": y,
                "gear_code": gcode,
                "gear": gname,
                "vessels": n_vessels,
                "fishing_days": int(round(fishing_days)),
            })
    return rows


# ---------------------------------------------------------------------------
# 4. Fisheries economics: access-fee revenue & exposure of public budgets
# ---------------------------------------------------------------------------
def economics(catch_rows):
    cc = {}
    for r in catch_rows:
        cc[(r["geo"], r["year"])] = cc.get((r["geo"], r["year"]), 0) + r["catch_tonnes"]
    rows = []
    for (code, y), total in sorted(cc.items()):
        t = y - 2000
        # delivered tuna value ~ USD 1,500/t; access fee take rises after the
        # PNA Vessel Day Scheme strengthens fees (~2012 onward).
        price = 1500.0 * (1 + 0.01 * t)
        fee_rate = 0.045 + (0.05 if y >= 2012 else 0.0)
        access_fee = total * price * fee_rate * (1 + noise(0.06))
        # government revenue scaled so the access fee is `dep` share of it
        dep = DEP[code] * (1 + 0.15 * (1 if y >= 2012 else 0))
        dep = min(0.85, dep)
        govt_rev = access_fee / max(0.03, dep)
        rows.append({
            "geo": code,
            "country": CODE_NAME[code],
            "year": y,
            "access_fee_usd": int(round(access_fee)),
            "govt_revenue_usd": int(round(govt_rev)),
            "fee_share_of_govt_revenue": round(access_fee / govt_rev, 4),
        })
    return rows


# ---------------------------------------------------------------------------
# Writers
# ---------------------------------------------------------------------------
def write_csv(path, rows, fields):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"  wrote {len(rows):>5} rows -> {os.path.relpath(path)}")


def main():
    print("Generating synthetic WCPO fisheries + SST sample data ...")
    sst = sst_anomaly()
    reg = regional_sst(sst)
    catch = tuna_catch(reg)
    ves = vessels(catch)
    econ = economics(catch)

    write_csv(os.path.join(RAW, "sst_anomaly.csv"), sst,
              ["geo", "country", "year", "indicator", "unit", "sst_anomaly_c"])
    write_csv(os.path.join(RAW, "tuna_catch.csv"), catch,
              ["geo", "country", "year", "species_code", "species", "catch_tonnes"])
    write_csv(os.path.join(RAW, "vessels.csv"), ves,
              ["geo", "country", "year", "gear_code", "gear", "vessels", "fishing_days"])
    write_csv(os.path.join(RAW, "fisheries_economics.csv"), econ,
              ["geo", "country", "year", "access_fee_usd", "govt_revenue_usd",
               "fee_share_of_govt_revenue"])

    # data dictionary + sources (metadata for the validate stage)
    dd = [
        ("sst_anomaly.csv", "geo", "ISO3 country/territory code", "character"),
        ("sst_anomaly.csv", "country", "Country / territory name", "character"),
        ("sst_anomaly.csv", "year", "Calendar year", "integer"),
        ("sst_anomaly.csv", "indicator", "SPC indicator name", "character"),
        ("sst_anomaly.csv", "unit", "Unit of measure", "character"),
        ("sst_anomaly.csv", "sst_anomaly_c", "Mean sea surface temperature anomaly vs baseline (degC)", "numeric"),
        ("tuna_catch.csv", "geo", "ISO3 country/territory code", "character"),
        ("tuna_catch.csv", "year", "Calendar year", "integer"),
        ("tuna_catch.csv", "species_code", "Tuna species code (SKJ/YFT/BET/ALB)", "character"),
        ("tuna_catch.csv", "species", "Tuna species name", "character"),
        ("tuna_catch.csv", "catch_tonnes", "Reported catch (metric tonnes)", "integer"),
        ("vessels.csv", "gear_code", "Gear code (PS/LL/PL)", "character"),
        ("vessels.csv", "gear", "Gear type", "character"),
        ("vessels.csv", "vessels", "Active licensed vessels in the EEZ", "integer"),
        ("vessels.csv", "fishing_days", "Total fishing days of effort", "integer"),
        ("fisheries_economics.csv", "access_fee_usd", "Tuna access-fee revenue (USD)", "integer"),
        ("fisheries_economics.csv", "govt_revenue_usd", "Total government revenue (USD)", "integer"),
        ("fisheries_economics.csv", "fee_share_of_govt_revenue", "Access fees as share of govt revenue (0-1)", "numeric"),
    ]
    write_csv(os.path.join(META, "data_dictionary.csv"),
              [dict(file=a, column=b, description=c, type=d) for a, b, c, d in dd],
              ["file", "column", "description", "type"])

    sources = [
        dict(dataset="sst_anomaly.csv",
             indicator="Mean sea surface temperature anomaly",
             pdh_agency="SPC", pdh_dataflow="DF_SST_ANOMALY", pdh_version="1.0",
             status="SYNTHETIC SAMPLE - replace with live PDH .Stat pull",
             url="https://stats.pacificdata.org/"),
        dict(dataset="tuna_catch.csv",
             indicator="WCPO tuna catch by species",
             pdh_agency="SPC", pdh_dataflow="DF_TUNA_CATCH", pdh_version="1.0",
             status="SYNTHETIC SAMPLE - replace with live PDH/OFP pull",
             url="https://stats.pacificdata.org/"),
        dict(dataset="vessels.csv",
             indicator="Licensed fishing vessels & effort",
             pdh_agency="SPC", pdh_dataflow="DF_TUNA_EFFORT", pdh_version="1.0",
             status="SYNTHETIC SAMPLE - replace with live PDH/OFP pull",
             url="https://stats.pacificdata.org/"),
        dict(dataset="fisheries_economics.csv",
             indicator="Tuna access-fee revenue",
             pdh_agency="SPC", pdh_dataflow="DF_FISH_ECON", pdh_version="1.0",
             status="SYNTHETIC SAMPLE - illustrative",
             url="https://stats.pacificdata.org/"),
    ]
    write_csv(os.path.join(META, "sources.csv"), sources,
              ["dataset", "indicator", "pdh_agency", "pdh_dataflow",
               "pdh_version", "status", "url"])

    # ---- validation / sanity report so we KNOW the story holds -------------
    print("\nSanity checks (the narrative must actually be in the numbers):")
    # (a) regional SST trend
    yrs = YEARS
    sst_by_year = [reg[y] for y in yrs]
    print(f"  SST anomaly {yrs[0]}: {sst_by_year[0]:.2f} degC  ->  "
          f"{yrs[-1]}: {sst_by_year[-1]:.2f} degC")

    # (b) catch centre-of-gravity longitude per year, and its correlation w/ SST
    cog = []
    for y in yrs:
        num = den = 0.0
        for r in catch:
            if r["year"] == y:
                num += LON[r["geo"]] * r["catch_tonnes"]
                den += r["catch_tonnes"]
        cog.append(num / den)
    print(f"  Catch centre-of-gravity longitude {yrs[0]}: {cog[0]:.1f}E  ->  "
          f"{yrs[-1]}: {cog[-1]:.1f}E  (east = warmer)")
    print(f"  corr(SST anomaly, catch longitude) = {pearson(sst_by_year, cog):+.2f}")

    # (c) most fishery-dependent budgets (latest year)
    last = max(yrs)
    dep_rows = sorted([r for r in econ if r["year"] == last],
                      key=lambda r: -r["fee_share_of_govt_revenue"])[:5]
    print(f"  Most fishery-dependent budgets in {last}:")
    for r in dep_rows:
        print(f"    {r['geo']}  access fees = "
              f"{r['fee_share_of_govt_revenue']*100:4.1f}% of govt revenue")

    total_last = sum(r["catch_tonnes"] for r in catch if r["year"] == last)
    print(f"  Total WCPO sample catch {last}: {total_last:,.0f} tonnes")
    print("Done.")


def pearson(a, b):
    n = len(a)
    ma, mb = sum(a) / n, sum(b) / n
    cov = sum((x - ma) * (y - mb) for x, y in zip(a, b))
    va = math.sqrt(sum((x - ma) ** 2 for x in a))
    vb = math.sqrt(sum((y - mb) ** 2 for y in b))
    return cov / (va * vb)


if __name__ == "__main__":
    main()
