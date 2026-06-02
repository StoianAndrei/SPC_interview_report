# =============================================================================
# 04_transform.R  --  harmonise the four sources into analysis-ready tables
# -----------------------------------------------------------------------------
# Stage 4. The cleaned datasets live at different grains (SST by country-year,
# catch by country-year-species, vessels by country-year-gear, economics by
# country-year). We reshape each to a common country-year grain, then JOIN them
# into one tidy "panel" plus a couple of derived series that carry the story:
#   - catch centre-of-gravity longitude (how far EAST the fishery sits)
#   - catch per vessel (efficiency / pressure)
#   - access-fee dependence (economic exposure)
# Every join is logged so a reader can see rows surviving each merge.
# =============================================================================

# Country reference (EEZ-centroid longitude on a 0-360 eastward scale, latitude,
# and PNA membership) used to compute the eastward centre-of-gravity and to
# place dots on the schematic Pacific map. Mirrors data-raw/generate_samples.py.
COUNTRY_REF <- tribble(
  ~geo,  ~lon360, ~lat,   ~pna,
  "PNG", 145.0,  -6.3,  TRUE,
  "SLB", 160.0,  -9.0,  TRUE,
  "FSM", 158.0,   6.9,  TRUE,
  "NRU", 166.9,  -0.5,  TRUE,
  "KIR", 185.0,   1.4,  TRUE,
  "MHL", 171.0,   7.1,  TRUE,
  "TUV", 178.7,  -7.5,  TRUE,
  "PLW", 134.5,   7.5,  TRUE,
  "TKL", 188.0,  -9.2,  FALSE,
  "FJI", 178.0, -17.7,  FALSE,
  "WSM", 188.2, -13.8,  FALSE,
  "COK", 200.2, -21.2,  FALSE,
  "PYF", 210.5, -17.5,  FALSE
)

#' Collapse the cleaned sources to country-year grain and join them.
transform_all <- function(clean) {
  # SST: already country-year
  sst <- clean$sst_anomaly %>%
    group_by(geo, country, year) %>%
    summarise(sst_anomaly_c = mean(sst_anomaly_c, na.rm = TRUE), .groups = "drop")

  # catch: sum across species -> total catch; keep species split separately
  catch_total <- clean$tuna_catch %>%
    group_by(geo, year) %>%
    summarise(catch_tonnes = sum(catch_tonnes, na.rm = TRUE), .groups = "drop")

  # vessels & effort: sum across gears
  effort <- clean$vessels %>%
    group_by(geo, year) %>%
    summarise(vessels = sum(vessels, na.rm = TRUE),
              fishing_days = sum(fishing_days, na.rm = TRUE), .groups = "drop")

  econ <- clean$fisheries_economics %>%
    select(geo, year, access_fee_usd, govt_revenue_usd,
           fee_share_of_govt_revenue)

  panel <- sst %>%
    left_join(catch_total, by = c("geo", "year"));            log_join("sst+catch", panel)
  panel <- panel %>% left_join(effort, by = c("geo", "year")); log_join("+effort", panel)
  panel <- panel %>% left_join(econ,   by = c("geo", "year")); log_join("+economics", panel)
  panel <- panel %>% left_join(COUNTRY_REF, by = "geo");       log_join("+geography", panel)

  panel <- panel %>%
    mutate(
      catch_per_vessel = if_else(vessels > 0, catch_tonnes / vessels, NA_real_),
      catch_kt = catch_tonnes / 1000
    ) %>%
    arrange(geo, year)

  log_stage("transform", "panel", panel,
            note = "country-year panel: SST + catch + effort + economics + geography",
            status = "ok")

  list(
    panel       = panel,
    catch_species = clean$tuna_catch %>%
      group_by(year, species_code, species) %>%
      summarise(catch_tonnes = sum(catch_tonnes, na.rm = TRUE), .groups = "drop"),
    cog         = catch_cog(clean$tuna_catch),
    region      = region_series(panel)
  )
}

#' lightweight helper so each join shows up in the lineage ledger
log_join <- function(label, df) {
  log_stage("transform", label, df, note = glue("joined: {label}"), status = "ok")
}

#' Catch centre-of-gravity longitude per year (catch-weighted mean EEZ longitude).
catch_cog <- function(tuna_catch) {
  tuna_catch %>%
    group_by(geo, year) %>%
    summarise(catch_tonnes = sum(catch_tonnes, na.rm = TRUE), .groups = "drop") %>%
    left_join(COUNTRY_REF, by = "geo") %>%
    group_by(year) %>%
    summarise(cog_lon = sum(lon360 * catch_tonnes) / sum(catch_tonnes),
              .groups = "drop")
}

#' Region-wide annual series (totals + the required SST indicator).
region_series <- function(panel) {
  panel %>%
    group_by(year) %>%
    summarise(
      sst_anomaly_c = mean(sst_anomaly_c, na.rm = TRUE),
      catch_kt      = sum(catch_tonnes, na.rm = TRUE) / 1000,
      vessels       = sum(vessels, na.rm = TRUE),
      access_fee_usd = sum(access_fee_usd, na.rm = TRUE),
      .groups = "drop"
    )
}
