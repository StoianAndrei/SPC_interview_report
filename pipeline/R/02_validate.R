# =============================================================================
# 02_validate.R  --  profile & validate raw data before we trust it
# -----------------------------------------------------------------------------
# Stage 2. A visualisation is only as honest as the data under it, so before any
# cleaning we PROFILE (types, ranges, missingness) and run explicit CHECKS
# against the data dictionary and common-sense bounds. The checks return a
# pass/fail ledger AND a missingness picture, so problems are visible, not
# buried.
# =============================================================================

#' Load the shipped data dictionary (column-level expectations).
load_dictionary <- function() {
  readr::read_csv(file.path(PATHS$meta, "data_dictionary.csv"),
                  show_col_types = FALSE, progress = FALSE)
}

#' Run validation checks across all raw datasets.
#'
#' Returns a tibble of checks (dataset, check, ok, detail). Keeps the pipeline
#' honest: every assertion we rely on downstream is stated and tested here.
validate_all <- function(raw) {
  checks <- list()
  add <- function(dataset, check, ok, detail = "")
    checks[[length(checks) + 1L]] <<- tibble(dataset, check, ok, detail)

  # ---- expected key columns per dataset ------------------------------------
  expect_cols <- list(
    sst_anomaly         = c("geo", "year", "sst_anomaly_c"),
    tuna_catch          = c("geo", "year", "species_code", "catch_tonnes"),
    vessels             = c("geo", "year", "gear_code", "vessels", "fishing_days"),
    fisheries_economics = c("geo", "year", "access_fee_usd", "fee_share_of_govt_revenue")
  )
  for (nm in names(expect_cols)) {
    df <- raw[[nm]]
    have <- expect_cols[[nm]] %in% names(df)
    add(nm, "required columns present", all(have),
        glue("missing: {paste(expect_cols[[nm]][!have], collapse=', ')}"))
  }

  # ---- year range sanity ----------------------------------------------------
  for (nm in names(raw)) {
    yr <- suppressWarnings(as.integer(raw[[nm]]$year))
    add(nm, "year within 1990-2035",
        all(yr >= 1990 & yr <= 2035, na.rm = TRUE),
        glue("range {min(yr, na.rm=TRUE)}-{max(yr, na.rm=TRUE)}"))
  }

  # ---- non-negativity of physical quantities --------------------------------
  add("tuna_catch", "catch_tonnes >= 0",
      all(raw$tuna_catch$catch_tonnes >= 0, na.rm = TRUE))
  add("vessels", "vessels >= 0",
      all(raw$vessels$vessels >= 0, na.rm = TRUE))
  add("fisheries_economics", "fee share in [0,1]",
      all(raw$fisheries_economics$fee_share_of_govt_revenue >= 0 &
          raw$fisheries_economics$fee_share_of_govt_revenue <= 1, na.rm = TRUE))

  # ---- required indicator actually present ----------------------------------
  add("sst_anomaly", glue("required SPC indicator present"),
      REQUIRED_INDICATOR %in% unique(raw$sst_anomaly$indicator),
      REQUIRED_INDICATOR)

  res <- bind_rows(checks)
  for (nm in unique(res$dataset)) {
    sub <- res %>% filter(dataset == nm)
    log_stage("validate", nm, raw[[nm]],
              note = glue("{sum(sub$ok)}/{nrow(sub)} checks passed"),
              status = if (all(sub$ok)) "ok" else "fail")
  }
  res
}

#' Render the validation ledger as PASS/FAIL badges.
validation_report <- function(res) {
  res %>%
    mutate(result = cell_spec(
      if_else(ok, "PASS", "FAIL"), format = "html", color = "white",
      bold = TRUE, background = if_else(ok, "#2A9D8F", "#E4572E"))) %>%
    select(Dataset = dataset, Check = check, Result = result, Detail = detail) %>%
    kbl(escape = FALSE, format = "html") %>%
    kable_styling(bootstrap_options = c("striped", "hover", "condensed"),
                  full_width = TRUE, position = "center")
}

#' Missingness picture across all datasets (share of NA by column).
missingness_plot <- function(raw) {
  miss <- imap_dfr(raw, function(df, nm) {
    tibble(dataset = nm, column = names(df),
           pct_missing = map_dbl(df, ~ mean(is.na(.x)) * 100))
  })
  ggplot(miss, aes(column, dataset, fill = pct_missing)) +
    geom_tile(colour = "white") +
    geom_text(aes(label = ifelse(pct_missing > 0,
                                 sprintf("%.0f%%", pct_missing), "")),
              size = 3, colour = "white") +
    scale_fill_gradient(low = SPC_COLOURS$reef, high = SPC_COLOURS$warm,
                        limits = c(0, 100), name = "% missing") +
    labs(title = "Missingness map (raw data)",
         subtitle = "Green = complete; warm = gaps to handle before visualising",
         x = NULL, y = NULL, caption = SPC_CAPTION) +
    theme_spc() +
    theme(axis.text.x = element_text(angle = 30, hjust = 1))
}
