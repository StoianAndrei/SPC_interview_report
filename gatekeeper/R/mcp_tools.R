# =============================================================================
# mcp_tools.R  --  the deterministic MCP tool layer
# -----------------------------------------------------------------------------
# These are the local tools an Agent Deployment Framework (ADF) orchestrator
# hands to the local LLM (see mcp/tools.json). The division of labour is the
# point: the LLM decides WHICH tool to call and proposes arguments (e.g. "this
# column looks like a port name"); these R functions do the actual resolution
# against trusted local dictionaries / the validation engine. The LLM never
# invents codes, weights or zones, and nothing leaves the machine.
#
# Each maps onto one of the user's "multi-angle" agents:
#   infer_content_type   -> Data Archaeologist (discovery)
#   resolve_fao_species  -> Species Classifier
#   resolve_port_code    -> Data Archaeologist (UNLOCODE alignment)
#   validate_spatial_eez -> Sovereignty & EEZ Agent
#   query_vessel         -> Vessel Profiler
#   (validate_submission -> Temporal Sanity + all tiers; in validate.R)
# =============================================================================

# read the head of an uploaded file (headers + first n rows)
mcp_read_file_sample <- function(file_path, n = 5) {
  df <- readr::read_csv(file_path, n_max = n, show_col_types = FALSE,
                        progress = FALSE)
  list(columns = names(df), rows = utils::head(as.data.frame(df), n))
}

# infer the data category from column structure (LL vs PS logsheet, etc.)
mcp_infer_content_type <- function(columns) {
  cols <- .fold(columns)
  has <- function(...) any(.fold(c(...)) %in% cols)
  pick <- if (has("species_group", "interaction_type", "observation_id"))
            list("observer_bycatch", "non-target interaction columns present")
          else if (has("length_cm", "length", "sex", "talla"))
            list("size_composition", "length/sex measurement columns present")
          else if (has("event_seq", "activity_id"))
            list("em_longline", "event-sequence / activity columns present")
          else if (has("fad", "school", "set_type", "sets"))
            list("purse_seine", "FAD / school / set columns present")
          else if (has("hooks", "hk_btwn_flt", "anzuelos") ||
                   ("effort_unit" %in% cols))
            list("catch_effort", "hooks / effort columns present (longline logsheet)")
          else list("unknown", "no decisive columns matched")
  list(category = pick[[1]], confidence = if (pick[[1]] == "unknown") 0.2 else 0.85,
       reason = pick[[2]])
}

# free-text species -> FAO 3-letter code (delegates to the local dictionary)
mcp_resolve_fao <- function(raw_species_string) {
  codes <- translate_species(raw_species_string)
  prot <- REF$species$is_protected[match(codes, REF$species$species_code)]
  tibble(input = raw_species_string, fao_code = codes,
         resolved = codes != raw_species_string,
         protected = !is.na(prot) & prot == 1)
}

# free-text port -> 5-letter UNLOCODE
load_port_codes <- function(dir = GK_PATHS$reference) {
  p <- file.path(dir, "port_codes.csv")
  if (!file.exists(p)) return(tibble())
  readr::read_csv(p, show_col_types = FALSE, progress = FALSE)
}
mcp_resolve_port <- function(raw_port_string, ports = load_port_codes()) {
  if (!nrow(ports)) return(tibble(input = raw_port_string, unlocode = NA))
  lut <- ports %>%
    tidyr::separate_rows(aliases, sep = "\\|") %>%
    mutate(key = .fold(aliases))
  lut2 <- bind_rows(lut, ports %>% mutate(key = .fold(name)))
  key <- .fold(raw_port_string)
  code <- lut2$unlocode[match(key, lut2$key)]
  # also accept an already-valid UNLOCODE
  code[is.na(code) & grepl("^[A-Z]{5}$", raw_port_string)] <-
    raw_port_string[is.na(code) & grepl("^[A-Z]{5}$", raw_port_string)]
  tibble(input = raw_port_string, unlocode = code,
         resolved = !is.na(code))
}

# coordinate -> EEZ / high-seas pocket + on-land check (bounding-box default)
mcp_validate_eez <- function(latitude, longitude) {
  on_land <- any(vapply(seq_len(nrow(REF$land)),
    function(i) in_box(latitude, longitude, as.list(REF$land[i, ])), logical(1)))
  zone <- NA_character_; iso <- NA_character_
  for (i in seq_len(nrow(REF$eez))) {
    b <- as.list(REF$eez[i, ])
    if (in_box(latitude, longitude, b)) { zone <- b$country; iso <- b$code; break }
  }
  if (is.na(zone)) { zone <- "High seas / unresolved"; iso <- "HIGH" }
  list(latitude = latitude, longitude = longitude, computed_zone = zone,
       zone_code = iso, is_land = on_land)
}

# IUU blacklist: match any identifier against the offline WCPFC IUU list
load_iuu <- function(dir = GK_PATHS$reference) {
  p <- file.path(dir, "iuu_vessel_list.csv")
  if (!file.exists(p)) return(tibble())
  readr::read_csv(p, show_col_types = FALSE, progress = FALSE)
}
mcp_check_iuu <- function(identifiers, iuu = load_iuu()) {
  if (!nrow(iuu)) return(list(is_safe_to_ingest = TRUE, iuu_hits = list()))
  keys <- .fold(identifiers); keys <- keys[keys != ""]
  hits <- list()
  for (i in seq_len(nrow(iuu))) {
    cand <- setdiff(.fold(c(iuu$vessel_id[i], iuu$call_sign[i], iuu$imo[i],
                            iuu$vessel_name[i])), "")
    if (length(intersect(keys, cand)))
      hits[[length(hits) + 1]] <- list(vessel_name = iuu$vessel_name[i],
        flag = iuu$flag[i], reason = iuu$reason[i], cmm = iuu$cmm[i])
  }
  list(is_safe_to_ingest = length(hits) == 0, iuu_hits = hits)
}

# Charter reconciliation: who owns the catch on this date (chartering vs flag)?
load_charters <- function(dir = GK_PATHS$reference) {
  p <- file.path(dir, "vessel_charters.csv")
  if (!file.exists(p)) return(tibble())
  readr::read_csv(p, show_col_types = FALSE, progress = FALSE)
}
mcp_charter_status <- function(wcpfc_vid, activity_date, ch = load_charters()) {
  d <- as.character(activity_date)
  if (nrow(ch)) {
    m <- ch[.fold(ch$wcpfc_vid) == .fold(wcpfc_vid) &
            ch$start_date <= d & d <= ch$end_date, ]
    if (nrow(m))
      return(list(is_chartered = TRUE, reporting_country = m$charter_state[1],
                  flag_state = m$flag_state[1],
                  notes = paste0("catch attributed to chartering state ",
                                 m$charter_state[1])))
  }
  flag <- REF$registry$flag[match(wcpfc_vid, REF$registry$vessel_id)]
  list(is_chartered = FALSE, reporting_country = flag, flag_state = flag,
       notes = "standard flag-state attribution")
}

# Harvest-strategy view: catch composition + mixed-fishery / LRP advisory
mcp_harvest_insight <- function(rows) {
  df <- tibble::as_tibble(rows)
  s <- function(c) sum(to_num(df[[c]]), na.rm = TRUE)
  tot <- c(SKJ = s("catch_skj_kg"), YFT = s("catch_yft_kg"),
           BET = s("catch_bet_kg"), ALB = s("catch_alb_kg"))
  grand <- max(1, sum(tot)); bet_share <- unname(tot["BET"] / grand)
  list(composition_share = as.list(round(tot / grand, 3)),
       bigeye_share = round(bet_share, 3),
       advisory = if (bet_share > 0.15)
         sprintf("Elevated bigeye share (%.0f%%) in the mixed fishery — watch the 20%% LRP breach limit.",
                 100 * bet_share) else NULL)
}

# vessel id / call sign -> structural profile from the offline registry
mcp_query_vessel <- function(vessel_sign) {
  r <- REF$registry[match(vessel_sign, REF$registry$vessel_id), ]
  if (nrow(r) == 0 || is.na(r$vessel_id[1]))
    return(list(found = FALSE, vessel_sign = vessel_sign))
  list(found = TRUE, wcpfc_vid = r$vessel_id[1], vessel_name = r$vessel_name[1],
       flag_state = r$flag[1], gear_type = r$gear_code[1],
       max_hold_capacity_mt = r$hold_capacity_mt[1],
       max_speed_kn = r$max_speed_kn[1])
}
