# When the Fish Are the Budget — a glass-box data pipeline

**SPC data-visualisation contest entry.** A complete, reproducible pipeline that
goes from raw data on the **Pacific Data Hub** to a finished story — and
**visualises the data at every step in between**, so nothing is hidden between
the source and the picture.

The story: the contest's required indicator, **mean sea surface temperature
anomaly**, is linked to where Pacific tuna are caught, how many vessels chase
them, and how heavily several national budgets depend on tuna access fees.

> *"A well-made visualisation can do something a report never can… It can make a
> decision-maker change their mind, and that is real power — it belongs to all of
> us who can use this data, and use it responsibly."*

---

## The method: six steps, each one visible

| # | Stage | Module | What you see |
|---|-------|--------|--------------|
| 1 | **Ingest** | `R/01_ingest.R` | provenance card — live Pacific Data Hub vs cached sample |
| 2 | **Validate** | `R/02_validate.R` | pass/fail check ledger + missingness map |
| 3 | **Clean** | `R/03_clean.R` | before/after schema diff + signal-preserved density |
| 4 | **Transform** | `R/04_transform.R` | join funnel — rows surviving each merge |
| 5 | **Analyse** | `R/05_analyse.R` | the warming ↔ eastward-catch model |
| 6 | **Visualise** | `R/06_visualise.R` | six communication-grade pictures |

Every stage writes to a **lineage ledger** (`R/utils_viz.R`); `lineage_plot()`
turns that ledger into a single view of the data's journey. That ledger *is* the
"visualise ingestion at every step" idea.

## Layout

```
pipeline/
├── fisheries_pipeline.Rmd     # the glass-box report (render this)
├── render.R                   # Rscript helper to build the report
├── R/
│   ├── 00_config.R            # paths, PDH SDMX registry, theme
│   ├── utils_viz.R            # lineage ledger + glass-box helpers
│   ├── 01_ingest.R … 06_visualise.R
│   └── pipeline.R             # run_pipeline(): the whole thing end to end
├── data/
│   ├── raw/                   # cached SAMPLE inputs (offline fallback)
│   ├── clean/                 # written by the pipeline
│   └── meta/                  # data dictionary + sources
└── data-raw/generate_samples.py   # how the sample data was produced
```

## Run it

From the repo root, inside the project's R / Docker environment:

```r
# the whole report
Rscript pipeline/render.R
# or, a quick non-report smoke run that prints the headline numbers
Rscript pipeline/R/pipeline.R
```

```r
# interactively
source("pipeline/R/pipeline.R")
res <- run_pipeline()   # tries live PDH, falls back to the cached sample
print(res)
```

## Data: sample now, live when you want it

The numbers shipped here are a **synthetic sample** (built by
`data-raw/generate_samples.py`, clearly flagged in `data/meta/sources.csv`) so
the pipeline runs offline. It is calibrated to the real shape of the Western &
Central Pacific tuna fishery — skipjack-dominated, concentrated in **PNA**
waters, with the catch centre-of-gravity drifting **east** in warm years.

The ingest layer is wired to the genuine **Pacific Data Hub .Stat** SDMX REST
API. To go live, edit the registry in `R/00_config.R` — confirm each dataflow ID
and key in the [PDH .Stat Data Explorer](https://stats.pacificdata.org/) and the
pipeline will pull the real series automatically (and the provenance card will
say so). The SST anomaly series is the contest's required indicator.

## Why this design

- **Auditable.** Each transformation is logged; a reader can see exactly what
  happened to the data, which is the whole point of a glass box.
- **Offline-safe.** Live first, cached fallback — it always runs.
- **Reproducible.** One `run_pipeline()` call rebuilds everything.
- **Honest.** Provenance and synthetic-vs-real status are shown, not buried.

*Our people, our children, our future.*
