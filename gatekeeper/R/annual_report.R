# =============================================================================
# annual_report.R  --  Automated Reporting Agent: WCPFC Annual Report Part 1
# -----------------------------------------------------------------------------
# Members must submit a summarised Annual Report Part 1 to the Scientific
# Committee every August -- today a manual aggregation chore on top of the raw
# logs. Once the gateway has validated a country's catch/effort, this turns the
# clean data straight into the Part 1 summary tables (Markdown), so the tool
# becomes a time-saver, not just a gatekeeper.
# =============================================================================

generate_annual_report_part1 <- function(catch_effort, country, year = NULL,
                                          out_file = NULL) {
  df <- catch_effort %>% filter(.data$flag == country | is.na(.data$flag))
  if (!is.null(year) && "set_date" %in% names(df))
    df <- df %>% filter(substr(set_date, 1, 4) == as.character(year))
  yr <- if (!is.null(year)) year else "(all years)"

  catch_cols <- intersect(.catch_cols, names(df))
  by_species <- tibble(
    species = c("Skipjack (SKJ)", "Yellowfin (YFT)", "Bigeye (BET)", "Albacore (ALB)"),
    code = c("catch_skj_kg", "catch_yft_kg", "catch_bet_kg", "catch_alb_kg")) %>%
    filter(code %in% catch_cols) %>%
    mutate(tonnes = map_dbl(code, ~ sum(to_num(df[[.x]]), na.rm = TRUE) / 1000))

  by_gear <- df %>% group_by(gear_code) %>%
    summarise(trips = n_distinct(trip_id),
              effort = sum(to_num(effort_amount), na.rm = TRUE),
              catch_mt = sum(to_num(catch_total_kg), na.rm = TRUE) / 1000,
              .groups = "drop")

  md <- c(
    sprintf("# WCPFC Annual Report — Part 1 (auto-draft)"),
    sprintf("**Member:** %s    **Year:** %s    **Generated:** %s",
            country, yr, format(Sys.Date())),
    "",
    "> Auto-compiled by the Pre-Ingestion Gateway from validated logsheets. ",
    "> Figures are draft summaries for the Scientific Committee submission.",
    "",
    "## 1. Fishery overview",
    sprintf("- Trips reported: **%d**", n_distinct(df$trip_id)),
    sprintf("- Active vessels: **%d**", n_distinct(df$vessel_id)),
    sprintf("- Total reported catch: **%.1f tonnes**",
            sum(to_num(df$catch_total_kg), na.rm = TRUE) / 1000),
    "",
    "## 2. Catch by species (tonnes)",
    .md_table(by_species %>% transmute(Species = species,
                                       Tonnes = round(tonnes, 1))),
    "",
    "## 3. Effort and catch by gear",
    .md_table(by_gear %>% transmute(Gear = gear_code, Trips = trips,
                                    Effort = effort, `Catch (t)` = round(catch_mt, 1))),
    "",
    "## 4. Notes",
    "- Size-composition and observer/bycatch summaries follow once those ",
    "  submissions are validated through the gateway."
  )
  txt <- paste(md, collapse = "\n")
  if (!is.null(out_file)) writeLines(txt, out_file)
  txt
}

# minimal Markdown table from a data frame
.md_table <- function(d) {
  if (!nrow(d)) return("_(no data)_")
  hdr <- paste0("| ", paste(names(d), collapse = " | "), " |")
  sep <- paste0("| ", paste(rep("---", ncol(d)), collapse = " | "), " |")
  body <- apply(d, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |"))
  paste(c(hdr, sep, body), collapse = "\n")
}
