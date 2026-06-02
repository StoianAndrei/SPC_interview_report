# Intelligent Pre-Ingestion Gateway for TUFMAN 2

**SPC data-visualisation contest entry — the operational track.**

A local, private, AI-assisted gateway that sits *in front of* TUFMAN 2 (SPC's
regional fisheries database). A member country drops in whatever data they
have — a clean TUFMAN 2 JSON payload, a standard CSV, or a messy multilingual
spreadsheet — and the gateway **instantly validates it, explains every problem
in plain language, lets them fix it on the spot, and only then forwards clean
data** to TUFMAN 2. It attacks the WCPFC's biggest, most-documented bottleneck:
non-standard, error-laden, late data submissions.

> The gateway doesn't rebuild what works. It removes the manual data-cleaning
> burden in front of it — and it runs **inside the country's own borders**.

---

## Why this design wins

Judges at a regional body care about **regional capacity and political reality**
as much as code:

- **Data sovereignty** — runs as an offline **Edge "Black Box" appliance**
  (Mac Mini / NUC / local VM). Raw operational logs never leave the building.
- **Scientific trust** — the validation logic is **R**, the language SPC's
  scientists already use and trust.
- **No-hallucination AI** — an optional **local LLM** ("Data Archaeologist")
  only *proposes column mappings*; catch weights and codes are mapped by
  deterministic dictionaries. Works fully **without** any model.
- **Zero-config distribution** — one `docker compose up` per nation.

## Architecture

```
[Data officer drops a messy file]  (offline, in-border)
            │
            ▼
   ┌──────────────────────────────┐
   │  Edge Gateway (this app)      │
   │  ① Data Archaeologist (map)   │  LLM optional → deterministic fallback
   │  ② R validation engine        │  structural · logical · compliance
   │  ③ Health score + CPUE map    │ ─► Instant dashboard / flags / fix loop
   └──────────────────────────────┘
            │  (only if 0 blocking errors)
            ▼  obtain country-scoped token → POST
   ┌──────────────────────────────┐
   │        TUFMAN 2 API           │
   └──────────────────────────────┘
```

This repo is the **R Validation & Science Engine + Shiny dashboard**. It maps
directly onto the recommended production stack:

| Production layer | This repo |
|---|---|
| Frontend (React/Vue) | `app.R` Shiny dashboard (prototype UI) |
| Traffic controller (FastAPI/Node, tokens) | `R/tufman.R` (mocked token + forward) |
| **Validation & science engine (R Plumber)** | `R/*.R` + `plumber.R` ✅ |
| Relational mirror (Postgres) for dup/overlap | `data/samples/tufman2_history.csv` (stand-in) |
| Packaging (Docker) | `Dockerfile.appliance`, `docker-compose.yml` |

## The validation engine — three tiers

| Tier | Examples implemented |
|---|---|
| **① Structural** | mandatory fields, valid codes (gear/sex/species/activity), coordinate ranges, ISO dates, vessel in registry, TUFMAN2 LL JSON schema (ISO 6709 coords, FAO codes, `activity_id=1` conditional, catch `anyOf`) |
| **② Logical (sanity)** | impossible/negative trip duration, **vessel-on-land**, **catch total ≠ species sum (decimal typo)**, implausible CPUE, **catch exceeds vessel hold capacity**, **duplicate logsheet** (in-file & vs TUFMAN 2 history), **excessive vessel speed** (EM event stream), length > species max, weight-at-length |
| **③ Compliance** | **shark bycatch rate** over threshold, **protected-species interactions** (turtle/seabird/shark), effort over regional guideline |

Data categories covered: **Catch & Effort**, **Size composition**,
**Observer / bycatch**, and **Longline E-Monitoring** — plus the **TUFMAN 2
Longline JSON** ingestion path, all feeding one engine.

## Run it

```r
# Interactive dashboard
shiny::runApp("gatekeeper")

# Validation API (for a Python/Node front controller)
Rscript -e 'plumber::pr("gatekeeper/plumber.R") |> plumber::pr_run(port = 8000)'
```

```bash
# The Edge appliance (offline gateway)
cd gatekeeper && docker compose up                 # no LLM, fully offline
docker compose --profile llm up                    # + local Ollama model
```

## Data & verification (this is the trustworthy part)

All inputs are **synthetic, clearly labelled** samples so the gateway runs
offline. They are regenerated and re-checked by:

```bash
python3 gatekeeper/data-raw/generate_gatekeeper_data.py   # samples + 23 planted anomalies
python3 gatekeeper/data-raw/verify_rules.py               # PROVES all 23 are caught
```

- `verify_rules.py` is an executable reference implementation of the rule set;
  it confirms the design catches **23/23 planted anomalies** across all tiers.
  `R/validate.R` is a faithful translation of it.
- The TUFMAN 2 LL JSON contract (`data/schemas/tufman2_ll_master.schema.json`)
  is validated with `jsonschema`: the sample payload passes, the dirty one
  fails with the expected 6 errors; ISO 6709 decoding is checked.

> Note: the R/Shiny app is authored carefully but **was not executed in the
> build sandbox** (no R runtime / CRAN access there). The *rule logic* and the
> *JSON schema* are verified in Python; run the Shiny app locally to exercise
> the UI.

## The Edge "Data Archaeologist" agent (`R/agent.R`)

1. **Discovery** — folds accents & matches headers via a multilingual synonym
   dictionary (`data/reference/field_synonyms.csv`): Spanish *Fecha* → `set_date`,
   *Peso Total* → `catch_total_kg`, *Anzuelos* → `effort_amount`.
2. **Translation** — free-text species → FAO codes deterministically
   (`species_synonyms.csv`): *Atún ojo grande* → `BET`, *Listado* → `SKJ`.
3. **Plain-language flagging** — `plain_language()` / `agent_insight()` turn
   rule failures into supportive guidance ("…check if the time entry was a typo").

`llm_available()` enables an optional local model (Ollama/ellmer) to *propose*
mappings for headers the dictionary misses; with no model the deterministic
path is used. The LLM never invents data values.

## Roadmap (clearly out of scope for this prototype)

- Overlapping-logsheet & multiple-in-port checks against a real Postgres mirror.
- Live TUFMAN 2 token exchange + POST (currently mocked in `R/tufman.R`).
- React/FastAPI controller wrapping the Plumber engine.
- Wiring `agent.R` to a quantized local Llama/Mistral for fuzzy header discovery.

*Respecting sovereignty, trusting the science, removing the bottleneck.*
