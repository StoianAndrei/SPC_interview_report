# =============================================================================
# cpue.R  --  catch-per-unit-effort and the spatial fishing footprint
# -----------------------------------------------------------------------------
# Feeds the dashboard's leaflet map. Computes per-record CPUE, tags each point
# with whether it was flagged by the validation engine, and (optionally)
# aggregates to a grid so a dense submission stays legible.
# =============================================================================

compute_cpue <- function(df, findings = NULL) {
  catch_cols <- intersect(.catch_cols, names(df))
  total <- if ("catch_total_kg" %in% names(df)) to_num(df$catch_total_kg)
           else .species_sum(df)
  eff <- to_num(df$effort_amount)
  out <- df %>%
    mutate(.row = row_number(),
           lat = to_num(latitude), lon = to_num(longitude),
           total_catch_kg = total,
           cpue = ifelse(!is.na(eff) & eff > 0, total / eff, NA_real_))
  if (!is.null(findings) && nrow(findings)) {
    flagged_rows <- unique(findings$row[!is.na(findings$row)])
    out$flagged <- out$.row %in% flagged_rows
  } else {
    out$flagged <- FALSE
  }
  out %>% filter(!is.na(lat), !is.na(lon), lat >= -90, lat <= 90,
                 lon >= -180, lon <= 180)
}

# 5-degree grid aggregation of CPUE for a heat-style map layer
cpue_grid <- function(cpue_df, cell = 5) {
  cpue_df %>%
    mutate(glat = floor(lat / cell) * cell + cell / 2,
           glon = floor(lon / cell) * cell + cell / 2) %>%
    group_by(glat, glon) %>%
    summarise(n = n(), catch_kg = sum(total_catch_kg, na.rm = TRUE),
              mean_cpue = mean(cpue, na.rm = TRUE), .groups = "drop")
}
