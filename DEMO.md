# Demo script — 5 minutes, judge-ready

A suggested running order that tells the whole story. Everything runs locally
and offline.

## 0. Setup (once)
```bash
# Python pieces run anywhere; R pieces need R (or use the Docker appliance)
pip install pandas jsonschema
python3 gatekeeper/data-raw/generate_gatekeeper_data.py   # build the sample data
```

## 1. "Why the fish matter" (30s)
Open `pipeline/output/previews/story_preview.png` (or render
`pipeline/fisheries_pipeline.Rmd`). One image: warming ocean → tuna move east
(r≈+0.9) → Kiribati/Tuvalu/Nauru budgets 60–75% dependent on tuna fees.

## 2. The Edge appliance takes a *messy, foreign-language* file (2 min)
```bash
python3 adf/run_demo.py
```
Watch the local agents, with no model and no network:
- detect a **Spanish longline logsheet**, map `Fecha→set_date`, `Anzuelos→effort_amount`
- resolve `Atún ojo grande → BET`, each trip's **EEZ** (→ Nauru/Kiribati)
- **block ingestion** on an IUU-listed vessel, reattribute a **chartered**
  vessel's catch to Nauru
- catch the planted problems (out-of-range coordinate, catch > hold capacity,
  unregistered vessel) and **HOLD** the submission with plain-language guidance

## 3. The gateway dashboard (1.5 min)
```bash
R -e 'shiny::runApp("gatekeeper")'        # or: docker compose up  (in gatekeeper/)
```
- drop the bundled sample (or `gatekeeper/data/samples/messy_spanish_ll.csv`)
- show the **health score**, the **CPUE map** (flagged points in red), the
  **flags workspace** (fix a cell → re-validate), and the **LL-JSON tab**
  (clean passes, dirty fails the schema)
- once clean → **token + conditional forward** to TUFMAN 2 (mock GUID returned)

## 4. "It's not just a demo — it's proven" (30s)
Show the green CI run: the **R engine actually executes** in CI (25/25 planted
anomalies caught), the JSON schema validates, and the Shiny server logic passes
a headless smoke test. See `.github/workflows/ci.yml`.

## Talking points
- **Sovereignty:** offline Docker appliance; raw logs never leave the building.
- **Trust:** validation in R (what SPC uses); the LLM never invents values.
- **Standards:** TUFMAN 2 LL JSON, WCPFC categories, IUU list, charters,
  harvest strategies, Annual Report Part 1.
