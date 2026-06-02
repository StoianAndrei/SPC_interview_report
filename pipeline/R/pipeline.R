# =============================================================================
# pipeline.R  --  run the whole glass-box pipeline end to end
# -----------------------------------------------------------------------------
# Sources every stage module and exposes run_pipeline(): one call that ingests,
# validates, cleans, transforms, analyses and (optionally) writes the cleaned
# data + figures. Returns a single object the Rmd report walks through, with the
# lineage ledger recorded along the way.
#
# Usage (from repo root or pipeline/):
#   source("pipeline/R/pipeline.R")
#   res <- run_pipeline()          # offline-safe: live PDH, else cached sample
# =============================================================================

`%||%` <- function(a, b) if (is.null(a)) b else a

# Source every stage module. Resolve the module directory by probing the usual
# locations so this works from the repo root, from pipeline/, or from the Rmd.
local({
  cand <- c("R", "pipeline/R", file.path(getwd(), "pipeline", "R"))
  here <- cand[file.exists(file.path(cand, "00_config.R"))]
  here <- if (length(here)) here[[1]] else "pipeline/R"
  for (f in c("00_config.R", "utils_viz.R", "01_ingest.R", "02_validate.R",
              "03_clean.R", "04_transform.R", "05_analyse.R", "06_visualise.R")) {
    source(file.path(here, f), local = FALSE)
  }
})

#' Run the end-to-end pipeline.
#'
#' @param use_live  try the live Pacific Data Hub first (TRUE), or go straight
#'                  to the cached sample (FALSE).
#' @param write     write cleaned CSVs + figure PNGs to disk.
run_pipeline <- function(use_live = TRUE, write = TRUE) {
  reset_lineage()

  raw      <- ingest_all(use_live = use_live)
  checks   <- validate_all(raw)
  cleaned  <- clean_all(raw)
  tf       <- transform_all(cleaned)
  shift    <- analyse_shift(tf)
  dep      <- analyse_dependence(tf)
  head     <- analyse_headlines(tf)

  if (write) {
    for (nm in names(cleaned)) {
      readr::write_csv(cleaned[[nm]], file.path(PATHS$clean, paste0(nm, ".csv")))
    }
    readr::write_csv(tf$panel, file.path(PATHS$clean, "panel.csv"))
  }

  structure(
    list(raw = raw, checks = checks, cleaned = cleaned, tf = tf,
         shift = shift, dependence = dep, headlines = head,
         lineage = lineage_tbl()),
    class = "spc_pipeline"
  )
}

print.spc_pipeline <- function(x, ...) {
  h <- x$headlines
  cat("SPC fisheries glass-box pipeline\n")
  cat(sprintf("  period            : %d-%d\n", h$year_from, h$year_to))
  cat(sprintf("  SST anomaly       : %.2f -> %.2f degC\n", h$sst_from, h$sst_to))
  cat(sprintf("  eastward shift    : +%.1f deg lon (r = %+.2f with SST)\n",
              h$east_shift_deg, h$shift_r))
  cat(sprintf("  catch (last yr)   : %s kt across %s vessels\n",
              format(round(h$catch_to_kt), big.mark = ","),
              format(h$vessels_to, big.mark = ",")))
  cat(sprintf("  most exposed      : %s (%.0f%% of govt revenue from access fees)\n",
              h$top_dep_country, 100 * h$top_dep_share))
  cat(sprintf("  pipeline steps    : %d logged\n", nrow(x$lineage)))
  invisible(x)
}

# Allow `Rscript pipeline/R/pipeline.R` for a quick non-report smoke run.
if (sys.nframe() == 0 && identical(environment(), globalenv())) {
  res <- run_pipeline()
  print(res)
}
