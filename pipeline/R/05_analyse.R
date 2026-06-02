# =============================================================================
# 05_analyse.R  --  turn the harmonised panel into the evidence for the story
# -----------------------------------------------------------------------------
# Stage 5. We quantify the three claims the final visuals make:
#   1. A warming ocean tracks an EASTWARD shift of the tuna fishery
#      (correlation + linear fit of catch centre-of-gravity on SST anomaly).
#   2. Effort (vessels) and catch have grown together.
#   3. Several island economies are heavily exposed to tuna access fees.
# Outputs are plain tibbles/lists so the report can quote exact numbers.
# =============================================================================

#' Correlation & linear model: catch centre-of-gravity ~ regional SST anomaly.
analyse_shift <- function(tf) {
  d <- tf$region %>% inner_join(tf$cog, by = "year")
  fit <- lm(cog_lon ~ sst_anomaly_c, data = d)
  list(
    data = d,
    r    = cor(d$sst_anomaly_c, d$cog_lon, use = "complete.obs"),
    slope = unname(coef(fit)["sst_anomaly_c"]),
    fit  = fit,
    east_shift_deg = max(d$cog_lon) - min(d$cog_lon)
  )
}

#' Latest-year ranking of economic exposure to tuna access fees.
analyse_dependence <- function(tf, top_n = 8) {
  last <- max(tf$panel$year, na.rm = TRUE)
  tf$panel %>%
    filter(year == last, !is.na(fee_share_of_govt_revenue)) %>%
    transmute(geo, country, year,
              fee_share = fee_share_of_govt_revenue,
              access_fee_usd) %>%
    arrange(desc(fee_share)) %>%
    slice_head(n = top_n)
}

#' Headline numbers for the executive summary / abstract.
analyse_headlines <- function(tf) {
  r <- tf$region
  shift <- analyse_shift(tf)
  dep <- analyse_dependence(tf, top_n = 1)
  first <- r %>% slice_min(year, n = 1)
  last  <- r %>% slice_max(year, n = 1)
  list(
    year_from        = first$year,
    year_to          = last$year,
    sst_from         = first$sst_anomaly_c,
    sst_to           = last$sst_anomaly_c,
    catch_to_kt      = last$catch_kt,
    vessels_to       = last$vessels,
    east_shift_deg   = shift$east_shift_deg,
    shift_r          = shift$r,
    top_dep_country  = dep$country,
    top_dep_share    = dep$fee_share
  )
}
