# =============================================================================
# plumber.R  --  expose the R validation engine as a private local API
# -----------------------------------------------------------------------------
# This is the "Validation & Science Engine: R" in the recommended architecture
# (FastAPI/Node controller -> R Plumber engine -> SQL/TUFMAN 2). A Python or
# Node front-end posts a submission here; R runs the three-tier checks and
# returns the findings + a green light. Run with:
#
#   Rscript -e 'plumber::pr("gatekeeper/plumber.R") |> plumber::pr_run(port=8000)'
# =============================================================================
source("gatekeeper/global.R")

#* Health probe
#* @get /healthz
function() list(status = "ok", time = format(Sys.time(), tz = "UTC"))

#* Validate a tabular submission (CSV already parsed to JSON rows).
#* @param category catch_effort|size_composition|observer_bycatch|em_longline
#* @post /validate
function(req, category = "catch_effort") {
  df <- jsonlite::fromJSON(req$postBody, simplifyDataFrame = TRUE)
  df <- tibble::as_tibble(df)
  findings <- validate_submission(df, category, REF, gk_context())
  status <- submission_status(findings, nrow(df))
  list(category = category, status = status,
       findings = findings, can_forward = status$can_forward)
}

#* Validate a TUFMAN 2 Longline JSON payload (schema + flattened logic).
#* @post /validate/tufman2-ll
function(req) {
  doc <- jsonlite::fromJSON(req$postBody, simplifyVector = TRUE,
                            simplifyDataFrame = FALSE)
  schema_findings <- validate_tufman2_ll(doc)
  if (nrow(schema_findings))
    return(list(stage = "schema", valid = FALSE, findings = schema_findings))
  tab <- tufman2_ll_to_catch_effort(doc, REF$registry)
  findings <- validate_submission(tab, "catch_effort", REF, gk_context())
  status <- submission_status(findings, nrow(tab))
  list(stage = "logic", valid = status$can_forward, status = status,
       findings = findings, flattened_rows = nrow(tab))
}
