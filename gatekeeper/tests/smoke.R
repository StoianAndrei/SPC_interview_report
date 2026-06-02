#!/usr/bin/env Rscript
# =============================================================================
# smoke.R  --  execute the whole R engine and PROVE it works
# -----------------------------------------------------------------------------
# This is the R-executable counterpart to data-raw/verify_rules.py. It loads the
# engine, validates every bundled sample, and asserts that each planted anomaly
# in the ground-truth manifest is caught. It also exercises the MCP tools and
# the TUFMAN 2 LL JSON path. Intended to run in CI (where R + CRAN are
# available); exits non-zero on any failure.
#
#   Rscript gatekeeper/tests/smoke.R
# =============================================================================
suppressWarnings(suppressMessages(source("gatekeeper/global.R")))

fails <- 0
ok <- function(name, cond) {
  cat(sprintf("  [%s] %s\n", if (isTRUE(cond)) "PASS" else "FAIL", name))
  if (!isTRUE(cond)) fails <<- fails + 1
}

# ---- 1. validate every category and collect findings -----------------------
ctx <- gk_context()
f_ce <- validate_submission(GK_SAMPLES$catch_effort, "catch_effort", REF, ctx)
f_sc <- validate_submission(GK_SAMPLES$size_composition, "size_composition", REF, ctx)
f_ob <- validate_submission(GK_SAMPLES$observer_bycatch, "observer_bycatch", REF, ctx)
f_em <- validate_submission(GK_SAMPLES$em_longline, "em_longline", REF, ctx)
all_f <- dplyr::bind_rows(f_ce, f_sc, f_ob, f_em)
cat(sprintf("Engine raised %d findings across 4 categories.\n", nrow(all_f)))

# ---- 2. every planted anomaly must be caught (vs the manifest) -------------
manifest <- readr::read_csv(file.path(GK_PATHS$samples, "injected_issues.csv"),
                            show_col_types = FALSE)
caught <- 0
for (i in seq_len(nrow(manifest))) {
  m <- manifest[i, ]
  hit <- any(all_f$category == m$category & all_f$record_id == m$record_id &
               all_f$rule == m$rule)
  if (hit) caught <- caught + 1
  else cat(sprintf("    MISSED: %s / %s / %s\n", m$category, m$record_id, m$rule))
}
ok(sprintf("all %d planted anomalies caught (%d)", nrow(manifest), caught),
   caught == nrow(manifest))

# ---- 3. MCP tools ----------------------------------------------------------
ok("infer_content_type: longline",
   mcp_infer_content_type(c("Fecha", "Anzuelos", "Especie"))$category == "catch_effort")
ok("resolve_fao: Atun ojo grande -> BET",
   mcp_resolve_fao("Atún ojo grande")$fao_code[1] == "BET")
ok("resolve_port: Pohnpei Port -> FMPNI",
   mcp_resolve_port("Pohnpei Port")$unlocode[1] == "FMPNI")
ok("validate_eez: Nauru point", mcp_validate_eez(-0.54, 166.91)$zone_code == "NRU")
ok("query_vessel: known vessel found", isTRUE(mcp_query_vessel("WCPFC-1001")$found))
ok("IUU: blacklisted vessel blocks", !mcp_check_iuu("WCPFC-9999")$is_safe_to_ingest)
ok("charter: WCPFC-11774 -> NRU in 2026",
   mcp_charter_status("WCPFC-11774", "2026-06-03")$reporting_country == "NRU")
ok("pre-PAW readiness assessed",
   !is.null(mcp_assess_prepaw(GK_SAMPLES$catch_effort)$region7_records))

# ---- 4. TUFMAN 2 LL JSON path ----------------------------------------------
clean <- ingest_tufman2_ll(file.path(GK_PATHS$samples, "tufman2_ll_sample.json"),
                           REF$registry)
dirty <- ingest_tufman2_ll(file.path(GK_PATHS$samples, "tufman2_ll_dirty.json"),
                           REF$registry)
ok("LL JSON: clean sample passes schema", nrow(clean$schema_findings) == 0)
ok("LL JSON: clean sample flattens to rows", nrow(clean$table) >= 1)
ok("LL JSON: dirty sample fails schema", nrow(dirty$schema_findings) > 0)

# ---- 5. health score + annual report ---------------------------------------
hs <- health_score(GK_SAMPLES$catch_effort, "catch_effort", f_ce)
ok("health score in 0..100", hs$score >= 0 && hs$score <= 100)
rpt <- generate_annual_report_part1(GK_SAMPLES$catch_effort, "FJI")
ok("annual report renders markdown", grepl("Annual Report", rpt))

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0) "ALL R SMOKE TESTS PASSED" else "R SMOKE TESTS FAILED",
            fails, if (fails == 1) "" else "s"))
quit(status = if (fails == 0) 0 else 1)
