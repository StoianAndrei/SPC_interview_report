# =============================================================================
# 01_ingest.R  --  acquire raw data (live Pacific Data Hub, else cached sample)
# -----------------------------------------------------------------------------
# Stage 1 of the pipeline. For each indicator we try the genuine PDH .Stat SDMX
# endpoint; if the network (or the host allow-list) blocks it, we transparently
# fall back to the cached sample CSV. Either way we record PROVENANCE so the
# report can show exactly where every number came from -- the first thing a
# responsible visualisation owes its audience.
# =============================================================================

#' Build the SDMX-REST data URL for a Pacific Data Hub dataflow.
pdh_url <- function(agency, dataflow, version, key = "all") {
  glue("{PDH$base}/data/{agency},{dataflow},{version}/{key}?format={PDH$format}")
}

#' Try to fetch one indicator live from PDH; return NULL on any failure.
pdh_try_fetch <- function(ind) {
  url <- pdh_url(ind$agency, ind$dataflow, ind$version, ind$key)
  out <- tryCatch({
    # readr handles the SDMX-CSV; short timeout so an offline run fails fast.
    old <- options(timeout = PDH$timeout); on.exit(options(old), add = TRUE)
    df <- suppressWarnings(
      readr::read_csv(url, show_col_types = FALSE, progress = FALSE))
    if (nrow(df) == 0) NULL else df
  }, error = function(e) NULL)
  out
}

#' Ingest every indicator in the registry.
#'
#' Returns a named list of raw tibbles, and attaches a `provenance` attribute
#' (one row per indicator: source = "Pacific Data Hub (live)" or "cached
#' sample", the URL tried, row count, and fetch time).
ingest_all <- function(use_live = TRUE) {
  raw <- list()
  prov <- list()
  for (i in seq_len(nrow(INDICATORS))) {
    ind <- INDICATORS[i, ]
    url <- pdh_url(ind$agency, ind$dataflow, ind$version, ind$key)

    df <- if (use_live) pdh_try_fetch(ind) else NULL
    source <- "Pacific Data Hub .Stat (live SDMX)"

    if (is.null(df)) {
      cache_path <- file.path(PATHS$raw, ind$cache)
      df <- readr::read_csv(cache_path, show_col_types = FALSE, progress = FALSE)
      source <- "Cached sample (offline fallback)"
    }

    raw[[ind$name]] <- df
    prov[[i]] <- tibble(
      dataset       = ind$name,
      spc_indicator = ind$spc_indicator,
      source        = source,
      url           = url,
      rows          = nrow(df),
      retrieved_at  = format(Sys.time(), "%Y-%m-%d %H:%M")
    )

    log_stage("ingest", ind$name, df,
              note = glue("Acquired from {source}"),
              status = if (grepl("live", source)) "ok" else "warn")
  }
  attr(raw, "provenance") <- bind_rows(prov)
  raw
}

#' Styled provenance card for the report.
provenance_table <- function(raw) {
  attr(raw, "provenance") %>%
    mutate(source = cell_spec(
      source, format = "html", color = "white", bold = TRUE,
      background = if_else(grepl("live", source), "#2A9D8F", "#F2C14E"))) %>%
    select(Dataset = dataset, `SPC indicator` = spc_indicator,
           Source = source, Rows = rows, Retrieved = retrieved_at) %>%
    kbl(escape = FALSE, format = "html") %>%
    kable_styling(bootstrap_options = c("striped", "hover", "condensed"),
                  full_width = TRUE, position = "center")
}
