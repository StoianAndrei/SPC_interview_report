#!/usr/bin/env python3
"""
preview_story.py  --  a static PREVIEW of the six story visuals.

This is NOT part of the R pipeline; it just reads the SAME cached CSVs and draws
the same six pictures with matplotlib so the story can be eyeballed without an R
runtime. The authoritative, interactive versions live in fisheries_pipeline.Rmd.
"""
import os
import pandas as pd
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.normpath(os.path.join(HERE, "..", "data", "raw"))
OUT = os.path.normpath(os.path.join(HERE, "..", "output", "previews"))
os.makedirs(OUT, exist_ok=True)

DEEP, OCEAN, WARM, SAND, REEF, GREY = (
    "#0B3C5D", "#1D6E8C", "#E4572E", "#F2C14E", "#2A9D8F", "#8896A6")

ref = pd.DataFrame([
    ("PNG",145.0,-6.3,True),("SLB",160.0,-9.0,True),("FSM",158.0,6.9,True),
    ("NRU",166.9,-0.5,True),("KIR",185.0,1.4,True),("MHL",171.0,7.1,True),
    ("TUV",178.7,-7.5,True),("PLW",134.5,7.5,True),("TKL",188.0,-9.2,False),
    ("FJI",178.0,-17.7,False),("WSM",188.2,-13.8,False),("COK",200.2,-21.2,False),
    ("PYF",210.5,-17.5,False)],
    columns=["geo","lon360","lat","pna"])

sst = pd.read_csv(f"{RAW}/sst_anomaly.csv")
catch = pd.read_csv(f"{RAW}/tuna_catch.csv")
ves = pd.read_csv(f"{RAW}/vessels.csv")
econ = pd.read_csv(f"{RAW}/fisheries_economics.csv")

region_sst = sst.groupby("year")["sst_anomaly_c"].mean()
cat_cy = catch.groupby(["geo","year"])["catch_tonnes"].sum().reset_index().merge(ref, on="geo")
cog = (cat_cy.assign(w=lambda d: d.lon360*d.catch_tonnes)
       .groupby("year").apply(lambda d: d.w.sum()/d.catch_tonnes.sum()))
region_catch = catch.groupby("year")["catch_tonnes"].sum()/1000
region_ves = ves.groupby("year")["vessels"].sum()
species = catch.groupby(["year","species"])["catch_tonnes"].sum().unstack()/1000

fig = plt.figure(figsize=(15, 12))
fig.suptitle("When the Fish Are the Budget — story preview (mirrors the R report)",
             fontsize=16, fontweight="bold", color=DEEP, y=0.985)
gs = GridSpec(3, 2, figure=fig, hspace=0.42, wspace=0.22)

# 1 warming
ax = fig.add_subplot(gs[0, 0])
ax.plot(region_sst.index, region_sst.values, color=WARM, lw=2.2, marker="o")
z = np.polyfit(region_sst.index, region_sst.values, 1)
ax.plot(region_sst.index, np.polyval(z, region_sst.index), "--", color=DEEP, lw=1)
ax.set_title("1. The ocean is warming (required SPC indicator)", color=DEEP, fontweight="bold")
ax.set_ylabel("SST anomaly (°C)"); ax.axhline(0, color=GREY, lw=.5)

# 2 eastward shift
ax = fig.add_subplot(gs[0, 1])
sc = ax.scatter(region_sst.values, cog.values, c=region_sst.index, cmap="YlOrRd", s=45)
z = np.polyfit(region_sst.values, cog.values, 1)
xs = np.linspace(region_sst.min(), region_sst.max(), 50)
ax.plot(xs, np.polyval(z, xs), color=DEEP, lw=1.5)
r = np.corrcoef(region_sst.values, cog.values)[0, 1]
ax.set_title(f"2. As it warms, tuna move east (r={r:+.2f})", color=DEEP, fontweight="bold")
ax.set_xlabel("SST anomaly (°C)"); ax.set_ylabel("Catch centre-of-gravity (°E)")
plt.colorbar(sc, ax=ax, label="Year")

# 3 species area
ax = fig.add_subplot(gs[1, 0])
order = ["Skipjack","Yellowfin","Bigeye","Albacore"]
cols = [OCEAN, SAND, WARM, REEF]
ax.stackplot(species.index, *[species[s] for s in order], labels=order, colors=cols)
ax.set_title("3. A million-tonne harvest, led by skipjack", color=DEEP, fontweight="bold")
ax.set_ylabel("Catch (kt)"); ax.legend(loc="upper left", fontsize=8)

# 4 vessel dot map
ax = fig.add_subplot(gs[1, 1])
ylast = ves.year.max()
vy = ves[ves.year == ylast].groupby("geo")["vessels"].sum().reset_index().merge(ref, on="geo")
ax.axvline(180, ls=":", color=GREY)
for _, row in vy.iterrows():
    ax.scatter(row.lon360, row.lat, s=row.vessels/2.0,
               color=OCEAN if row.pna else SAND, alpha=.65)
    ax.text(row.lon360, row.lat+1.6, row.geo, ha="center", fontsize=7, color=DEEP)
ax.set_title(f"4. Where the fleet fishes ({ylast}, bubble=vessels)", color=DEEP, fontweight="bold")
ax.set_xlabel("Longitude (°E, east →)"); ax.set_ylabel("Latitude")

# 5 catch vs vessels
ax = fig.add_subplot(gs[2, 0])
ax.bar(region_catch.index, region_catch.values, color=OCEAN, alpha=.85)
ax.set_ylabel("Catch (kt)", color=OCEAN)
ax2 = ax.twinx()
ax2.plot(region_ves.index, region_ves.values, color=WARM, lw=2.2, marker="o")
ax2.set_ylabel("Active vessels", color=WARM)
ax.set_title("5. More vessels, more catch", color=DEEP, fontweight="bold")

# 6 dependence
ax = fig.add_subplot(gs[2, 1])
dep = (econ[econ.year == econ.year.max()]
       .sort_values("fee_share_of_govt_revenue").tail(8))
ax.barh(dep.country, dep.fee_share_of_govt_revenue*100, color=DEEP)
for y, v in zip(range(len(dep)), dep.fee_share_of_govt_revenue*100):
    ax.text(v+1, y, f"{v:.0f}%", va="center", color=DEEP, fontsize=8)
ax.set_title(f"6. When the fish are the budget ({econ.year.max()})", color=DEEP, fontweight="bold")
ax.set_xlabel("Access fees, % of govt revenue")

out = f"{OUT}/story_preview.png"
fig.savefig(out, dpi=110, bbox_inches="tight", facecolor="white")
print("wrote", os.path.relpath(out, os.path.join(HERE, "..", "..")))
