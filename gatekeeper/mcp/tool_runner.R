#!/usr/bin/env Rscript
# =============================================================================
# tool_runner.R  --  production dispatcher for the MCP tool layer
# -----------------------------------------------------------------------------
# The ADF's RscriptBackend (adf/mcp_client.py) calls:
#     Rscript gatekeeper/mcp/tool_runner.R <tool_name>   < args.json   > result.json
# This loads the trusted R engine and routes the call to the matching function,
# so the orchestrator gets identical results to the Python reference backend but
# computed by the real scientific engine.
# =============================================================================
suppressWarnings(suppressMessages(source("gatekeeper/global.R")))
library(jsonlite)

args <- commandArgs(trailingOnly = TRUE)
tool <- args[[1]]
a <- tryCatch(fromJSON(file("stdin"), simplifyVector = TRUE), error = function(e) list())

result <- switch(tool,
  read_local_file_sample = mcp_read_file_sample(a$file_path, a$n %||% 5),
  infer_content_type     = mcp_infer_content_type(a$columns),
  resolve_fao_species_code = mcp_resolve_fao(a$raw_species_string),
  resolve_port_code      = mcp_resolve_port(a$raw_port_string),
  validate_spatial_eez   = mcp_validate_eez(a$latitude, a$longitude),
  query_local_vessel_registry = mcp_query_vessel(a$vessel_sign),
  check_iuu_status       = mcp_check_iuu(a$identifiers),
  lookup_vessel_charter_status = mcp_charter_status(a$wcpfc_vid, a$activity_date),
  harvest_strategy_check = mcp_harvest_insight(a$rows),
  assess_prepaw_readiness = mcp_assess_prepaw(a$rows),
  render_national_report_part1 = mcp_render_report_part1(a$country_code, a$reporting_year),
  execute_r_validation   = {
    df <- tibble::as_tibble(a$rows)
    f <- validate_submission(df, a$category, REF, gk_context())
    list(findings = f, status = submission_status(f, nrow(df)))
  },
  generate_annual_report_part1 = generate_annual_report_part1(
    GK_SAMPLES$catch_effort, a$country, a$year),
  stop("unknown tool: ", tool))

cat(toJSON(result, auto_unbox = TRUE, dataframe = "rows", na = "null"))
