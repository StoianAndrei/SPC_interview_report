# =============================================================================
# 00_config.R  --  paths, the Pacific Data Hub indicator registry, and theme
# -----------------------------------------------------------------------------
# Central place for everything the pipeline stages share. Keeping the live PDH
# endpoints here (rather than scattered through the code) means swapping the
# cached sample for a real pull is a one-line change per indicator.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(janitor)
  library(glue)
})

# ---- paths ------------------------------------------------------------------
# Resolve paths relative to the `pipeline/` folder regardless of the working
# directory the report or `make` is launched from.
PIPE_ROOT <- local({
  # when sourced from the Rmd, knitr sets the chunk wd to the Rmd's dir
  cand <- c(".", "pipeline", file.path(getwd(), "pipeline"))
  hit <- cand[file.exists(file.path(cand, "R", "00_config.R"))]
  normalizePath(if (length(hit)) hit[[1]] else ".", mustWork = FALSE)
})

PATHS <- list(
  raw      = file.path(PIPE_ROOT, "data", "raw"),
  meta     = file.path(PIPE_ROOT, "data", "meta"),
  clean    = file.path(PIPE_ROOT, "data", "clean"),
  figs     = file.path(PIPE_ROOT, "output", "figs")
)
for (p in c(PATHS$clean, PATHS$figs)) {
  if (!dir.exists(p)) dir.create(p, recursive = TRUE, showWarnings = FALSE)
}

# ---- Pacific Data Hub .Stat (SDMX-REST) registry ----------------------------
# The .Stat suite that powers the Pacific Data Hub speaks SDMX. The REST data
# query has the shape:
#
#   {base}/data/{agency},{dataflow},{version}/{key}?{params}
#
# and can return SDMX-CSV when asked with the right `format`/Accept header. The
# `key` is a dot-separated filter over the dataflow's dimensions ("all" = no
# filter). Confirm the exact dataflow IDs/keys in the PDH .Stat Data Explorer
# (https://stats.pacificdata.org/) before a live run -- they are filled in here
# with sensible defaults and can be overridden per indicator.
PDH <- list(
  base    = "https://stats.pacificdata.org/rest",
  format  = "csvfilewithlabels",   # SDMX-CSV with human-readable labels
  timeout = 60
)

# One row per indicator the pipeline ingests. `dataflow`/`key` are what get
# swapped for the genuine series; `cache` is the offline fallback fixture;
# `rename` maps the SDMX columns onto the tidy names the rest of the pipeline
# expects so downstream stages never care whether data came live or from cache.
INDICATORS <- tribble(
  ~name,                 ~spc_indicator,                          ~agency, ~dataflow,        ~version, ~key,  ~cache,
  "sst_anomaly",         "Mean sea surface temperature anomaly",  "SPC",   "DF_SST_ANOMALY", "1.0",    "all", "sst_anomaly.csv",
  "tuna_catch",          "WCPO tuna catch by species",            "SPC",   "DF_TUNA_CATCH",  "1.0",    "all", "tuna_catch.csv",
  "vessels",             "Licensed fishing vessels & effort",     "SPC",   "DF_TUNA_EFFORT", "1.0",    "all", "vessels.csv",
  "fisheries_economics", "Tuna access-fee revenue",               "SPC",   "DF_FISH_ECON",   "1.0",    "all", "fisheries_economics.csv"
)

# The single SPC indicator we are *required* to use for the contest.
REQUIRED_INDICATOR <- "Mean sea surface temperature anomaly"

# ---- look-and-feel ----------------------------------------------------------
# A small Pacific-leaning palette used consistently across every stage so the
# "glass box" panels read as one piece.
SPC_COLOURS <- list(
  deep   = "#0B3C5D",  # deep ocean
  ocean  = "#1D6E8C",  # lagoon
  warm   = "#E4572E",  # warming / alert
  sand   = "#F2C14E",  # sand / highlight
  reef   = "#2A9D8F",  # reef
  grey   = "#8896A6"
)

theme_spc <- function(base_size = 12) {
  theme_minimal(base_size = base_size) +
    theme(
      plot.title    = element_text(face = "bold", colour = SPC_COLOURS$deep),
      plot.subtitle = element_text(colour = SPC_COLOURS$grey),
      plot.caption  = element_text(colour = SPC_COLOURS$grey, size = base_size - 3),
      panel.grid.minor = element_blank(),
      strip.text    = element_text(face = "bold", colour = SPC_COLOURS$deep)
    )
}

SPC_CAPTION <- paste0(
  "Source: Pacific Data Hub .Stat (synthetic sample in this build). ",
  "SPC data-visualisation contest · indicator: sea surface temperature anomaly."
)
