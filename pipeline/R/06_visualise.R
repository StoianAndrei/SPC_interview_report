# =============================================================================
# 06_visualise.R  --  the final story: "a picture that says what the numbers
#                     have been saying for years"
# -----------------------------------------------------------------------------
# Stage 6. Six communication-grade visuals, each one earned by an earlier
# pipeline stage:
#   v1  warming ocean (the required SPC indicator) over time
#   v2  the tuna fishery drifts EAST as the ocean warms (the link)
#   v3  catch by species growing through the period
#   v4  a schematic Pacific "dot map": vessels by EEZ, early vs late
#   v5  catch vs vessels -- effort and harvest rising together
#   v6  economic exposure: tuna access fees as a share of govt revenue
# All return ggplot objects; the Rmd renders them (interactive via plotly where
# it helps).
# =============================================================================

#' v1 -- the required indicator: regional sea surface temperature anomaly.
viz_warming <- function(tf) {
  ggplot(tf$region, aes(year, sst_anomaly_c)) +
    geom_hline(yintercept = 0, linewidth = 0.3, colour = SPC_COLOURS$grey) +
    geom_line(colour = SPC_COLOURS$warm, linewidth = 1.2) +
    geom_point(colour = SPC_COLOURS$warm, size = 2) +
    geom_smooth(method = "lm", se = FALSE, linetype = "dashed",
                colour = SPC_COLOURS$deep, linewidth = 0.6) +
    scale_y_continuous(labels = label_number(suffix = " °C")) +
    labs(title = "The ocean is warming across the Pacific",
         subtitle = "Mean sea surface temperature anomaly — the required SPC indicator",
         x = NULL, y = "SST anomaly", caption = SPC_CAPTION) +
    theme_spc()
}

#' v2 -- the link: catch centre-of-gravity longitude vs SST anomaly.
viz_eastward_shift <- function(tf, shift) {
  d <- shift$data
  ggplot(d, aes(sst_anomaly_c, cog_lon)) +
    geom_path(colour = SPC_COLOURS$grey, linewidth = 0.4, alpha = 0.7) +
    geom_smooth(method = "lm", se = TRUE, colour = SPC_COLOURS$deep,
                fill = SPC_COLOURS$ocean, alpha = 0.15, linewidth = 0.8) +
    geom_point(aes(colour = year), size = 3) +
    scale_colour_gradient(low = SPC_COLOURS$reef, high = SPC_COLOURS$warm,
                          name = "Year") +
    scale_y_continuous(labels = label_number(suffix = "°E")) +
    labs(title = "As the ocean warms, the tuna move east",
         subtitle = sprintf("Catch centre-of-gravity vs SST anomaly  (r = %+.2f, +%.1f° east over the record)",
                            shift$r, shift$east_shift_deg),
         x = "SST anomaly (°C)", y = "Catch centre-of-gravity (longitude)",
         caption = SPC_CAPTION) +
    theme_spc()
}

#' v3 -- catch by species over time (skipjack dominates).
viz_species <- function(tf) {
  ggplot(tf$catch_species,
         aes(year, catch_tonnes / 1000, fill = reorder(species, -catch_tonnes))) +
    geom_area(alpha = 0.9, colour = "white", linewidth = 0.2) +
    scale_fill_manual(values = c(Skipjack = SPC_COLOURS$ocean,
                                 Yellowfin = SPC_COLOURS$sand,
                                 Bigeye = SPC_COLOURS$warm,
                                 Albacore = SPC_COLOURS$reef), name = "Species") +
    scale_y_continuous(labels = label_comma()) +
    labs(title = "A million-tonne harvest, led by skipjack",
         subtitle = "WCPO tuna catch by species",
         x = NULL, y = "Catch (thousand tonnes)", caption = SPC_CAPTION) +
    theme_spc()
}

#' v4 -- schematic Pacific dot map: vessels by EEZ, first vs last year.
#' (Uses EEZ-centroid coordinates rather than a heavyweight shapefile so the
#'  pipeline stays dependency-light; longitude on a 0-360 eastward scale.)
viz_vessel_map <- function(clean) {
  yrs <- range(clean$vessels$year, na.rm = TRUE)
  d <- clean$vessels %>%
    filter(year %in% yrs) %>%
    group_by(geo, year) %>%
    summarise(vessels = sum(vessels, na.rm = TRUE), .groups = "drop") %>%
    left_join(COUNTRY_REF, by = "geo") %>%
    mutate(period = factor(year, labels = c("first year", "last year")))
  ggplot(d, aes(lon360, lat)) +
    geom_vline(xintercept = 180, linetype = "dotted", colour = SPC_COLOURS$grey) +
    annotate("text", x = 180, y = max(d$lat) + 2, label = "Date line",
             colour = SPC_COLOURS$grey, size = 3) +
    geom_point(aes(size = vessels, colour = pna), alpha = 0.7) +
    geom_text(aes(label = geo), size = 2.6, colour = SPC_COLOURS$deep,
              vjust = -1.4) +
    facet_wrap(~ period, ncol = 1) +
    scale_size_area(max_size = 16, labels = label_comma(), name = "Vessels") +
    scale_colour_manual(values = c(`TRUE` = SPC_COLOURS$ocean,
                                   `FALSE` = SPC_COLOURS$sand),
                        labels = c(`TRUE` = "PNA waters", `FALSE` = "Other"),
                        name = NULL) +
    labs(title = "Where the fleet fishes",
         subtitle = "Active vessels by EEZ (bubble size) — schematic Pacific layout",
         x = "Longitude (°E, east →)", y = "Latitude",
         caption = SPC_CAPTION) +
    theme_spc()
}

#' v5 -- catch and vessels rising together (dual encoding).
viz_catch_effort <- function(tf) {
  d <- tf$region
  scale <- max(d$catch_kt) / max(d$vessels)
  ggplot(d, aes(year)) +
    geom_col(aes(y = catch_kt), fill = SPC_COLOURS$ocean, alpha = 0.85) +
    geom_line(aes(y = vessels * scale), colour = SPC_COLOURS$warm, linewidth = 1.2) +
    geom_point(aes(y = vessels * scale), colour = SPC_COLOURS$warm, size = 2) +
    scale_y_continuous(
      name = "Catch (thousand tonnes)", labels = label_comma(),
      sec.axis = sec_axis(~ . / scale, name = "Active vessels",
                          labels = label_comma())) +
    labs(title = "More vessels, more catch — rising pressure on the stock",
         subtitle = "Bars: catch (left axis)   Line: active vessels (right axis)",
         x = NULL, caption = SPC_CAPTION) +
    theme_spc() +
    theme(axis.title.y.right = element_text(colour = SPC_COLOURS$warm),
          axis.title.y.left  = element_text(colour = SPC_COLOURS$ocean))
}

#' v6 -- economic exposure: access fees as a share of government revenue.
viz_dependence <- function(dep) {
  ggplot(dep, aes(reorder(country, fee_share), fee_share)) +
    geom_col(fill = SPC_COLOURS$deep) +
    geom_text(aes(label = percent(fee_share, accuracy = 1)),
              hjust = -0.15, colour = SPC_COLOURS$deep, size = 3.5) +
    coord_flip() +
    scale_y_continuous(labels = label_percent(),
                       expand = expansion(mult = c(0, 0.18))) +
    labs(title = "When the fish are the budget",
         subtitle = sprintf("Tuna access fees as a share of government revenue (%d)",
                            dep$year[[1]]),
         x = NULL, y = "Share of government revenue", caption = SPC_CAPTION) +
    theme_spc()
}
