# =============================================================================
# helpers.R  --  shared utilities, reference-data loader, theme
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(stringr)
  library(purrr)
})

# ---- paths ------------------------------------------------------------------
gk_root <- function() {
  cand <- c(".", "gatekeeper", file.path(getwd(), "gatekeeper"))
  hit <- cand[file.exists(file.path(cand, "R", "helpers.R"))]
  normalizePath(if (length(hit)) hit[[1]] else ".", mustWork = FALSE)
}
GK_PATHS <- local({
  root <- gk_root()
  list(root = root,
       reference = file.path(root, "data", "reference"),
       samples   = file.path(root, "data", "samples"),
       templates = file.path(root, "data", "templates"))
})

# ---- palette / status colours ----------------------------------------------
GK_COL <- list(ok = "#2A9D8F", warn = "#F2C14E", error = "#E4572E",
               deep = "#0B3C5D", ocean = "#1D6E8C", grey = "#8896A6")
SEVERITY <- c(structural = "error", logical = "error", compliance = "warning")
SEV_COL  <- c(error = GK_COL$error, warning = GK_COL$warn, ok = GK_COL$ok)

# ---- small predicates (mirror verify_rules.py) ------------------------------
is_blank <- function(x) is.na(x) | trimws(as.character(x)) == ""

to_num <- function(x) suppressWarnings(as.numeric(x))

is_iso_date <- function(x) {
  d <- suppressWarnings(as.Date(as.character(x), format = "%Y-%m-%d"))
  !is.na(d) & format(d, "%Y-%m-%d") == as.character(x)
}

# great-circle distance in nautical miles (vectorised)
haversine_nm <- function(lat1, lon1, lat2, lon2) {
  R <- 3440.065
  p1 <- lat1 * pi / 180; p2 <- lat2 * pi / 180
  dphi <- (lat2 - lat1) * pi / 180
  dl   <- (lon2 - lon1) * pi / 180
  a <- sin(dphi / 2)^2 + cos(p1) * cos(p2) * sin(dl / 2)^2
  R * 2 * atan2(sqrt(a), sqrt(1 - a))
}

# point-in-box that tolerates date-line-spanning boxes (lon_min > lon_max)
in_box <- function(lat, lon, b) {
  lon_ok <- if (b$lon_min <= b$lon_max) lon >= b$lon_min & lon <= b$lon_max
            else lon >= b$lon_min | lon <= b$lon_max
  lat >= b$lat_min & lat <= b$lat_max & lon_ok
}

# ---- reference data ---------------------------------------------------------
load_reference <- function(dir = GK_PATHS$reference) {
  rd <- function(f) readr::read_csv(file.path(dir, f), show_col_types = FALSE,
                                    progress = FALSE)
  thr_tbl <- rd("compliance_thresholds.csv")
  list(
    species   = rd("species_ref.csv"),
    registry  = rd("vessel_registry.csv"),
    eez       = rd("eez_bounds.csv"),
    land      = rd("land_bounds.csv"),
    thresholds = setNames(thr_tbl$threshold, thr_tbl$rule_id),
    threshold_tbl = thr_tbl
  )
}

# convenience threshold accessor
thr <- function(ref, id) unname(ref$thresholds[[id]])

# ---- a finding row ----------------------------------------------------------
# Every rule emits findings via this helper so the schema is uniform.
new_findings <- function() {
  tibble(category = character(), record_id = character(), row = integer(),
         tier = character(), rule = character(), field = character(),
         message = character())
}
finding <- function(category, record_id, row, tier, rule, field = NA_character_,
                     message = "") {
  tibble(category = category, record_id = as.character(record_id),
         row = as.integer(row), tier = tier, rule = rule,
         field = field, message = message)
}
