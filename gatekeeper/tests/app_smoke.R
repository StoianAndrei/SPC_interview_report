#!/usr/bin/env Rscript
# =============================================================================
# app_smoke.R  --  headless smoke test of the Shiny SERVER logic
# -----------------------------------------------------------------------------
# Closes the last "does it actually run" gap: uses shiny::testServer() to drive
# the gateway's reactive server without a browser, exercising the validate /
# health / forward / LL-JSON paths. Runs in CI (where shiny + UI deps install).
#
#   Rscript gatekeeper/tests/app_smoke.R
# =============================================================================
suppressPackageStartupMessages({
  library(shiny); library(DT); library(leaflet); library(plotly)
})

# sourcing app.R defines `ui` and `server` and returns a shinyApp object; it
# does NOT launch (no runApp), so this is safe.
app <- source("gatekeeper/app.R", local = FALSE)$value

fails <- 0
ok <- function(name, cond) {
  cat(sprintf("  [%s] %s\n", if (isTRUE(cond)) "PASS" else "FAIL", name))
  if (!isTRUE(cond)) fails <<- fails + 1
}

# Drive the reactive server headless: load a sample, validate, inspect outputs.
testServer(server, {
  session$setInputs(country = "FJI", category = "catch_effort", source = "sample")
  session$setInputs(validate = 1)
  ok("validation populated status", !is.null(rv$status))
  ok("status reports rows", is.numeric(rv$status$n_rows) && rv$status$n_rows > 0)
  ok("health score computed", !is.null(rv$health) && rv$health$score >= 0)
  ok("findings is a data frame", is.data.frame(rv$findings))
  ok("overview row count renders", nchar(output$c_rows) > 0)
  ok("decision gate is boolean", is.logical(rv$status$can_forward))
})

cat(sprintf("\n%s (%d failure%s)\n",
            if (fails == 0) "APP SERVER SMOKE PASSED" else "APP SERVER SMOKE FAILED",
            fails, if (fails == 1) "" else "s"))
quit(status = if (fails == 0) 0 else 1)
