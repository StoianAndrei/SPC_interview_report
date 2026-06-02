# SPC Data-Visualisation Contest — Solution Overview

**One sentence:** a fully local, AI-assisted **Pre-Ingestion Gateway for TUFMAN 2**
that turns messy, multilingual fisheries logsheets into clean, validated,
standards-compliant submissions — and tells the story of *why the fish matter*
— without a single byte of sensitive data leaving the country.

This repository holds **three proven-in-CI tracks** that build on one another.

---

## The problem (from the WCPFC's own documentation)

- Member countries submit **non-standard, inconsistently formatted** data;
  cleaning it is a massive manual burden on SPC scientists, delaying real-time
  insight by weeks or months.
- A failed API call returns an intimidating raw `400`, so officers **fall back
  to emailing zip files** — pushing the cleaning burden back to SPC.
- **Data sovereignty** fears make countries reluctant to upload raw operational
  logs anywhere central.
- Climate change is **moving the tuna** that Pacific economies depend on.

## The three tracks

### 1. `pipeline/` — the visualisation narrative ("why the fish matter")
A glass-box R pipeline (ingest → validate → clean → transform → analyse →
visualise) that links the **required SPC indicator** (sea-surface-temperature
anomaly) to the eastward drift of the tuna fishery and the **national budgets
that depend on it** (Kiribati/Tuvalu/Nauru: 60–75% of government revenue from
tuna access fees). Every pipeline stage is itself visualised — the data's
journey is the story.

### 2. `gatekeeper/` — the operational gateway (R engine + Shiny + MCP tools)
The heart of the entry. A **three-tier validation engine**
(structural → logical → compliance) over four data categories plus the
**TUFMAN 2 Longline JSON** contract:

- **Structural:** mandatory fields, codes, coordinate ranges, ISO dates, vessel
  registry, the LL-JSON schema (ISO 6709 coords, FAO codes, the `activity_id=1`
  conditional, the catch `anyOf` rule).
- **Logical:** impossible/negative trip duration, vessel-on-land, catch-total ≠
  species sum (decimal typo), implausible CPUE, catch > hold capacity, duplicate
  & overlapping logsheets, multiple-in-port, excessive vessel speed.
- **Compliance:** shark-bycatch rate, protected-species interactions, effort
  guidelines.

Plus: a **completeness health score**, a leaflet **CPUE map**, a fix-and-
re-validate **flags workspace**, **conditional forward** to TUFMAN 2 (token +
POST, mockable/live), an **SQLite mirror** for duplicate/overlap, and the engine
exposed as **MCP tools** + a **Plumber API**.

### 3. `adf/` — the Edge Agent Deployment Framework (local, AI-assisted)
A Python orchestrator that runs **entirely offline on a country's machine**. It
coordinates multi-agent handoffs over the deterministic MCP tools while a
*local* LLM (optional) only proposes column mappings:

- **Data Archaeologist** — infer type + map multilingual headers
  (*Fecha→set_date*, *Anzuelos→effort_amount*).
- **Species Classifier** — *Atún ojo grande→BET*, deterministically.
- **Sovereignty/EEZ** — coordinate → EEZ (−0.54,166.91 → Nauru).
- **Vessel Profiler**, **IUU Blacklist** (blocks listed hulls),
  **Charter Reconciliation** (reattributes catch to the chartering state),
  **Harvest-strategy** & **Pre-PAW** advisories.

## What makes it credible

- **Data sovereignty by design** — offline Docker appliance; the LLM never sees
  the network and never invents codes or weights.
- **Trust** — the science/validation layer is **R**, what SPC already uses.
- **Aligned to the real standards** — TUFMAN 2 LL JSON, WCPFC data categories,
  IUU list, charter rules, harvest strategies, Annual Report Part 1.

## Proven, not just written

Everything runnable is verified in **GitHub Actions CI** (`.github/workflows/ci.yml`):

| Job | Proves |
|---|---|
| Python verification | rule oracle (25/25 planted anomalies), TUFMAN2 JSON schema (clean passes / dirty fails), ADF end-to-end (17/17) |
| R engine smoke | the **R engine executes** on real R/CRAN: 25/25 anomalies + MCP tools + JSON path + health + report |
| Shiny server smoke | the Shiny **server logic runs** headless via `testServer()` |

See `gatekeeper/README.md`, `adf/README.md`, and `DEMO.md` to run each track.
