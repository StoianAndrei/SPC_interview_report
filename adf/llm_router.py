"""
llm_router.py
=============

The LLM's job in this architecture is narrow and safe: look at messy headers and
PROPOSE which MCP tool to call and with what arguments. It never computes catch
weights, codes or zones — the deterministic MCP tools do that.

  MockRouter   : deterministic, no model. Uses the same dictionaries the tools
                 use, so the appliance works fully offline with zero model.
  OllamaRouter : optional. Calls a LOCAL Ollama model for fuzzy header proposals
                 the dictionary misses; falls back to MockRouter on any failure.
"""
from __future__ import annotations
import json
import os
import urllib.request
import tools_reference as T


class MockRouter:
    name = "mock (deterministic, offline)"

    def propose_mapping(self, columns):
        """Propose canonical names for messy headers + a short rationale."""
        mapping = T.map_columns(columns)
        unmatched = [c for c in columns if c not in mapping]
        rationale = [f"'{src}' → {canon}" for src, canon in mapping.items()]
        return {"mapping": mapping, "unmatched": unmatched, "rationale": rationale}

    def explain(self, finding):
        return finding.get("message", "")


class OllamaRouter:
    """Optional local-model router. Used only if an Ollama endpoint is reachable."""
    name = "ollama (local model)"

    def __init__(self, host=None, model="llama3"):
        self.host = host or os.environ.get("OLLAMA_HOST", "http://localhost:11434")
        self.model = model
        self.fallback = MockRouter()

    def _available(self):
        try:
            urllib.request.urlopen(f"{self.host}/api/tags", timeout=2)
            return True
        except Exception:
            return False

    def propose_mapping(self, columns):
        if not self._available():
            return self.fallback.propose_mapping(columns)
        prompt = ("Map these fisheries logsheet column headers to the canonical "
                  "fields [trip_id, vessel_id, flag, gear_code, set_date, latitude, "
                  "longitude, effort_unit, effort_amount, target_species, "
                  "catch_total_kg]. Reply as JSON {original: canonical}. Headers: "
                  + json.dumps(columns))
        try:
            req = urllib.request.Request(
                f"{self.host}/api/generate",
                data=json.dumps({"model": self.model, "prompt": prompt,
                                 "stream": False, "format": "json"}).encode(),
                headers={"Content-Type": "application/json"})
            resp = json.loads(urllib.request.urlopen(req, timeout=60).read())
            mapping = json.loads(resp.get("response", "{}"))
            # the deterministic dictionary still wins where it has an answer
            mapping.update(T.map_columns(columns))
            unmatched = [c for c in columns if c not in mapping]
            return {"mapping": mapping, "unmatched": unmatched,
                    "rationale": ["local LLM proposal, dictionary-verified"]}
        except Exception:
            return self.fallback.propose_mapping(columns)

    def explain(self, finding):
        return finding.get("message", "")


def get_router():
    """Use a local model if one is reachable, else the deterministic router."""
    r = OllamaRouter()
    return r if r._available() else MockRouter()
