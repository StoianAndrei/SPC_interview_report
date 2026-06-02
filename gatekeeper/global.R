# =============================================================================
# global.R  --  loaded once when the Shiny app (or Plumber API) starts
# =============================================================================
suppressPackageStartupMessages({
  library(shiny)
  library(DT)
  library(leaflet)
  library(plotly)
  library(jsonlite)
})

# source the engine (order matters: helpers/schemas first)
local({
  here <- {
    cand <- c("R", "gatekeeper/R", file.path(getwd(), "gatekeeper", "R"))
    hit <- cand[file.exists(file.path(cand, "helpers.R"))]
    if (length(hit)) hit[[1]] else "R"
  }
  for (f in c("helpers.R", "schemas.R", "validate.R", "mapping.R",
              "health.R", "cpue.R", "tufman.R", "agent.R"))
    source(file.path(here, f), local = FALSE)
})

# reference data + bundled sample submissions
REF <- load_reference()

GK_SAMPLES <- local({
  rd <- function(f) readr::read_csv(file.path(GK_PATHS$samples, f),
                                    show_col_types = FALSE, progress = FALSE)
  list(
    catch_effort     = rd("catch_effort_sample.csv"),
    size_composition = rd("size_composition_sample.csv"),
    observer_bycatch = rd("observer_bycatch_sample.csv"),
    em_longline      = rd("em_longline_sample.csv"),
    history          = rd("tufman2_history.csv")
  )
})

# context passed to the validator (history for duplicate checks, effort for
# the shark-bycatch rate)
gk_context <- function() list(history = GK_SAMPLES$history,
                              effort = GK_SAMPLES$catch_effort)

CATEGORY_LABELS <- c(
  catch_effort     = "Catch & Effort",
  size_composition = "Size composition",
  observer_bycatch = "Observer / bycatch",
  em_longline      = "Longline E-Monitoring"
)
COUNTRY_CHOICES <- sort(unique(REF$registry$flag))
