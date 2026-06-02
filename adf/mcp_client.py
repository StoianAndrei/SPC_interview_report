"""
mcp_client.py
=============

A minimal Model Context Protocol client for the local appliance. It exposes the
declared tools (gatekeeper/mcp/tools.json) to the orchestrator and dispatches
each call to a backend:

  PythonReferenceBackend : runs tools_reference.py (no R needed; used here)
  RscriptBackend         : shells to Rscript gatekeeper/mcp/tool_runner.R, i.e.
                           the real R engine (used in production where R exists)

Either way the tool contract is identical, so the orchestrator code is unchanged
whether the science engine is the Python reference or the trusted R engine.
"""
from __future__ import annotations
import json
import os
import subprocess
import tools_reference as T

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "gatekeeper", "mcp", "tools.json")


class PythonReferenceBackend:
    name = "python-reference"

    DISPATCH = {
        "read_local_file_sample": lambda a: T.read_local_file_sample(a["file_path"], a.get("n", 5)),
        "infer_content_type":     lambda a: T.infer_content_type(a["columns"]),
        "map_columns":            lambda a: T.map_columns(a["columns"]),
        "resolve_fao_species_code": lambda a: T.resolve_fao(a["raw_species_string"]),
        "resolve_port_code":      lambda a: T.resolve_port(a["raw_port_string"]),
        "validate_spatial_eez":   lambda a: T.validate_spatial_eez(a["latitude"], a["longitude"]),
        "query_local_vessel_registry": lambda a: T.query_vessel(a["vessel_sign"]),
        "check_iuu_status":       lambda a: T.check_iuu_status(a["identifiers"]),
        "lookup_vessel_charter_status": lambda a: T.charter_status(a["wcpfc_vid"], a["activity_date"]),
        "harvest_strategy_check": lambda a: T.harvest_strategy_insight(a["rows"]),
        "execute_r_validation":   lambda a: {
            "findings": T.validate_catch_effort(a["rows"]),
            "status": T.submission_status(T.validate_catch_effort(a["rows"]), len(a["rows"]))},
    }

    def call(self, tool, args):
        if tool not in self.DISPATCH:
            raise KeyError(f"unknown tool: {tool}")
        return self.DISPATCH[tool](args)


class RscriptBackend:
    """Production backend: dispatch to the R engine via a tool runner script."""
    name = "rscript"

    def __init__(self, runner=None, rscript="Rscript"):
        self.runner = runner or os.path.join(ROOT, "gatekeeper", "mcp", "tool_runner.R")
        self.rscript = rscript

    def call(self, tool, args):
        proc = subprocess.run(
            [self.rscript, self.runner, tool],
            input=json.dumps(args), capture_output=True, text=True, timeout=120)
        if proc.returncode != 0:
            raise RuntimeError(f"R tool '{tool}' failed: {proc.stderr.strip()}")
        return json.loads(proc.stdout)


class MCPClient:
    def __init__(self, backend=None):
        self.backend = backend or PythonReferenceBackend()
        with open(MANIFEST) as f:
            self.manifest = json.load(f)
        self.declared = {t["name"] for t in self.manifest["tools"]}

    def call(self, tool, **args):
        # the ADF only lets the LLM invoke DECLARED tools (sandbox boundary)
        known = self.declared | {"map_columns", "check_iuu_status",
                                 "lookup_vessel_charter_status", "harvest_strategy_check"}
        if tool not in known:
            raise PermissionError(f"tool '{tool}' is not in the MCP manifest")
        return self.backend.call(tool, args)
