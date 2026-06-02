# ADF — local Agent Deployment Framework orchestrator

The Python orchestration layer for the offline Edge appliance. It coordinates
multi-agent handoffs over the **deterministic MCP tools** (the R engine), while
an optional **local LLM** only proposes column mappings. Nothing leaves the
machine.

```
[Messy file] → ADF Orchestrator
                 DISCOVERY  → infer type/language + map headers (LLM proposes)
                 SYNTHESIS  → standardise rows, resolve species → FAO
                 ENRICHMENT → EEZ/sovereignty, vessel profile, species
                 VALIDATION → three-tier engine (structural/logical/compliance)
                 DECISION   → READY_TO_FORWARD or HELD_FOR_REVIEW
```

## Design

- **Deterministic control.** `orchestrator.py` owns the state machine; the LLM
  never decides where data goes — it only routes to a declared MCP tool.
- **Two interchangeable backends** (`mcp_client.py`):
  - `PythonReferenceBackend` — pure Python (`tools_reference.py`); runs here with
    no R, and is the executable spec the R tools are checked against.
  - `RscriptBackend` — calls the real R engine via `gatekeeper/mcp/tool_runner.R`.
- **LLM optional** (`llm_router.py`): `MockRouter` (deterministic, offline) or
  `OllamaRouter` (local model, auto-falls back to mock).

## Run

```bash
python3 adf/run_demo.py            # drive the bundled messy Spanish logsheet
python3 adf/run_demo.py --json     # + full machine-readable result
python3 adf/test_adf.py            # 13 end-to-end assertions (all pass)
```

The demo shows the appliance taking a Spanish-language longline spreadsheet with
non-standard headers, mapping it (`Fecha`→`set_date`, `Anzuelos`→`effort_amount`,
`Atún ojo grande`→`BET`), resolving each trip's EEZ (`-0.54,166.91`→Nauru),
validating it, catching the planted problems (out-of-range coordinate, catch
exceeding hold capacity, unregistered vessel), and holding it for review with
plain-language guidance — entirely offline.

## Files

| File | Role |
|---|---|
| `orchestrator.py` | ADF state machine + multi-agent pipeline |
| `mcp_client.py` | MCP tool registry + Python/Rscript backends |
| `tools_reference.py` | pure-Python reference impl of the MCP tools |
| `llm_router.py` | deterministic router (+ optional Ollama) |
| `run_demo.py` / `test_adf.py` | demo + end-to-end tests |
