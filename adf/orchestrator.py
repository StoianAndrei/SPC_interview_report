"""
orchestrator.py
===============

The Agent Deployment Framework (ADF) orchestrator for the offline Edge
appliance. It owns the state machine and the multi-agent handoffs; the local
LLM (via llm_router) only proposes column mappings, and the deterministic MCP
tools (via mcp_client) do every resolution and validation. Nothing leaves the
machine.

State machine:  IDLE → DISCOVERY → SYNTHESIS → ENRICHMENT → VALIDATION → DECISION

Multi-angle agents (each = one or more MCP tools):
  Archaeologist     discover type/language + map columns
  Species Classifier resolve free-text species → FAO codes
  Vessel Profiler    resolve vessel ids → structural profile
  Sovereignty/EEZ    resolve coordinates → EEZ / on-land
  Temporal + tiers   the three-tier validation engine
"""
from __future__ import annotations
import csv
from mcp_client import MCPClient
from llm_router import get_router

# canonical catch_effort columns the synthesizer emits
CE_COLS = ["trip_id", "vessel_id", "flag", "gear_code", "set_date", "trip_days",
           "latitude", "longitude", "effort_unit", "effort_amount",
           "target_species", "species_code", "catch_skj_kg", "catch_yft_kg",
           "catch_bet_kg", "catch_alb_kg", "catch_total_kg"]
FAO_TO_COL = {"SKJ": "catch_skj_kg", "YFT": "catch_yft_kg",
              "BET": "catch_bet_kg", "ALB": "catch_alb_kg"}


class ADFOrchestrator:
    def __init__(self, mcp=None, router=None, verbose=True):
        self.mcp = mcp or MCPClient()
        self.router = router or get_router()
        self.state = "IDLE"
        self.verbose = verbose

    def log(self, msg):
        if self.verbose:
            print(f"[ADF:{self.state}] {msg}")

    # ---- the pipeline -------------------------------------------------------
    def handle_file(self, file_path):
        self.state = "DISCOVERY"
        sample = self.mcp.call("read_local_file_sample", file_path=file_path, n=5)
        cols = sample["columns"]
        ctype = self.mcp.call("infer_content_type", columns=cols)
        proposal = self.router.propose_mapping(cols)
        self.log(f"detected '{ctype['category']}' ({ctype['reason']}); "
                 f"language={ctype['language']}; router={self.router.name}")
        self.log(f"column mapping: {proposal['mapping']}")
        if proposal["unmatched"]:
            self.log(f"unmatched headers: {proposal['unmatched']}")

        self.state = "SYNTHESIS"
        rows = self._read_all(file_path)
        std_rows, species_seen = self._synthesize(rows, proposal["mapping"])
        self.log(f"standardised {len(std_rows)} rows to the catch_effort schema")

        # IUU gate (Agent 5): scan vessel identities BEFORE anything else
        ids = sorted({r["vessel_id"] for r in std_rows if r["vessel_id"]})
        iuu = self.mcp.call("check_iuu_status", identifiers=ids)
        if not iuu["is_safe_to_ingest"]:
            for h in iuu["iuu_hits"]:
                self.log(f"!! IUU MATCH: {h['vessel_name']} — {h['reason']} ({h['cmm']})")

        self.state = "ENRICHMENT"
        species = self.mcp.call("resolve_fao_species_code",
                                raw_species_string=sorted(species_seen))
        protected = [s["input"] for s in species if s["protected"]]
        self.log("species resolved: " +
                 ", ".join(f"{s['input']}→{s['fao_code']}" for s in species))
        zones, vessels, charter = self._enrich(std_rows)
        self.log(f"EEZ zones touched: {sorted(set(zones.values()))}")
        chartered = {t: c["reporting_country"] for t, c in charter.items() if c["is_chartered"]}
        if chartered:
            self.log(f"charter attribution (catch reassigned): {chartered}")
        unregistered = [v for v, p in vessels.items() if not p.get("found")]
        if unregistered:
            self.log(f"unregistered vessels: {unregistered}")

        self.state = "VALIDATION"
        res = self.mcp.call("execute_r_validation",
                            category="catch_effort", rows=std_rows)
        findings, status = res["findings"], res["status"]
        self.log(f"validation: {status['n_error']} errors, "
                 f"{status['n_warning']} warnings across {status['flagged_rows']} rows")

        harvest = self.mcp.call("harvest_strategy_check", rows=std_rows)
        if harvest.get("advisory"):
            self.log(f"harvest-strategy advisory: {harvest['advisory']}")
        prepaw = self.mcp.call("assess_prepaw_readiness", rows=std_rows)
        if prepaw.get("advisory"):
            self.log(f"pre-PAW advisory: {prepaw['advisory']}")

        self.state = "DECISION"
        if not iuu["is_safe_to_ingest"]:
            decision = "BLOCKED_IUU"
        elif status["can_forward"]:
            decision = "READY_TO_FORWARD"
        else:
            decision = "HELD_FOR_REVIEW"
        self.log(f"decision: {decision}")
        return {
            "content_type": ctype, "mapping": proposal,
            "standardised_rows": std_rows, "species": species,
            "protected_species": protected, "eez_zones": zones,
            "vessel_profiles": vessels, "charter_attribution": charter,
            "iuu": iuu, "harvest_strategy": harvest, "prepaw": prepaw,
            "findings": findings,
            "status": status, "decision": decision,
            "friendly_flags": [self._friendly(f) for f in findings]}

    # ---- agents (helpers) ---------------------------------------------------
    def _read_all(self, path):
        with open(path, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))

    def _synthesize(self, rows, mapping):
        """Apply the column mapping + resolve species into the standard schema."""
        out, species_seen = [], set()
        for r in rows:
            std = {c: "" for c in CE_COLS}
            for src, canon in mapping.items():
                if canon in std:
                    std[canon] = r.get(src, "")
            std["gear_code"] = std.get("gear_code") or "LL"
            std["effort_unit"] = std.get("effort_unit") or "HOOKS"
            # species text in 'species_code' slot -> FAO + the right catch column
            raw_sp = std.get("species_code", "")
            if raw_sp:
                species_seen.add(raw_sp)
                fao = self.mcp.call("resolve_fao_species_code",
                                    raw_species_string=[raw_sp])[0]["fao_code"]
                std["target_species"] = fao
                std["species_code"] = fao
                if fao in FAO_TO_COL and std.get("catch_total_kg"):
                    std[FAO_TO_COL[fao]] = std["catch_total_kg"]
            out.append(std)
        return out, species_seen

    def _enrich(self, std_rows):
        zones, vessels, charter = {}, {}, {}
        for r in std_rows:
            try:
                lat, lon = float(r["latitude"]), float(r["longitude"])
                if -90 <= lat <= 90 and -180 <= lon <= 180:
                    z = self.mcp.call("validate_spatial_eez", latitude=lat, longitude=lon)
                    zones[r["trip_id"]] = z["computed_zone"]
            except (ValueError, TypeError):
                zones[r["trip_id"]] = "unresolved (bad coordinate)"
            vid = r["vessel_id"]
            if vid and vid not in vessels:
                vessels[vid] = self.mcp.call("query_local_vessel_registry", vessel_sign=vid)
            # Charter reconciliation (Agent 6): who owns this catch on this date?
            c = self.mcp.call("lookup_vessel_charter_status",
                              wcpfc_vid=vid, activity_date=r.get("set_date", ""))
            charter[r["trip_id"]] = c
            r["flag"] = c.get("reporting_country") or r.get("flag")
        return zones, vessels, charter

    def _friendly(self, finding):
        return {"record": finding["record_id"], "severity": finding["severity"],
                "issue": finding["rule"], "explanation": self.router.explain(finding)}
