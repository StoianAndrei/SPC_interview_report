# =============================================================================
# validate.R  --  the three-tier validation engine
# -----------------------------------------------------------------------------
#   Tier 1 STRUCTURAL : mandatory fields, types, codes, coordinate ranges
#   Tier 2 LOGICAL    : physical/mathematical sanity (durations, on-land,
#                       catch-total math, CPUE, hold capacity, duplicates,
#                       excessive vessel speed)
#   Tier 3 COMPLIANCE : regional conservation/effort flags (shark bycatch,
#                       protected-species interactions, effort guidelines)
#
# This is a faithful R translation of gatekeeper/data-raw/verify_rules.py, which
# proves (runnably) that this rule set catches every planted anomaly. Keep the
# two in sync.
# =============================================================================

# helper: which land box(es) a point falls inside (vectorised over points)
.land_hits <- function(lat, lon, land) {
  hit <- rep(FALSE, length(lat))
  for (i in seq_len(nrow(land))) hit <- hit | in_box(lat, lon, as.list(land[i, ]))
  hit
}

.catch_cols <- c("catch_skj_kg", "catch_yft_kg", "catch_bet_kg", "catch_alb_kg")
.species_sum <- function(df) {
  present <- intersect(.catch_cols, names(df))
  if (!length(present)) return(rep(0, nrow(df)))
  Reduce(`+`, lapply(present, function(c) {
    v <- to_num(df[[c]]); ifelse(is.na(v), 0, v)
  }), rep(0, nrow(df)))
}

# --- Catch & Effort ----------------------------------------------------------
validate_catch_effort <- function(df, ref, history = NULL) {
  cat <- "catch_effort"; id <- "trip_id"
  ids <- if (id %in% names(df)) as.character(df[[id]]) else as.character(seq_len(nrow(df)))
  f <- new_findings()
  emit <- function(cond, tier, rule, field = NA_character_, msg = "") {
    cond[is.na(cond)] <- FALSE
    idx <- which(cond)
    if (length(idx))
      f <<- bind_rows(f, finding(cat, ids[idx], idx, tier, rule, field, msg))
  }

  lat <- to_num(df$latitude); lon <- to_num(df$longitude)
  td  <- to_num(df$trip_days); eff <- to_num(df$effort_amount)
  sp_sum <- .species_sum(df); total <- to_num(df$catch_total_kg)

  # ---- structural ----
  for (col in required_fields(cat)) {
    if (col %in% names(df))
      emit(is_blank(df[[col]]), "structural", "mandatory_field_missing", col,
           paste0(col, " is missing"))
    else
      emit(rep(TRUE, nrow(df)), "structural", "mandatory_field_missing", col,
           paste0(col, " column is absent"))
  }
  emit(!is_blank(df$vessel_id) & !(df$vessel_id %in% ref$registry$vessel_id),
       "structural", "vessel_not_registered", "vessel_id",
       "vessel_id is not in the WCPFC vessel registry")
  emit(!(df$gear_code %in% c("LL", "PS", "PL")),
       "structural", "invalid_code", "gear_code", "gear_code not in {LL, PS, PL}")
  emit(is.na(lat) | is.na(lon) | lat < -90 | lat > 90 | lon < -180 | lon > 180,
       "structural", "coordinate_out_of_range", "latitude/longitude",
       "coordinate outside valid range")
  emit(!is_iso_date(df$set_date),
       "structural", "invalid_date", "set_date", "set_date is not a valid ISO date")

  # ---- logical ----
  emit(!is.na(td) & td > thr(ref, "MAX_TRIP_DAYS"),
       "logical", "impossible_trip_duration", "trip_days",
       paste0("trip_days exceeds ", thr(ref, "MAX_TRIP_DAYS"), " days"))
  emit(!is.na(td) & td <= 0,
       "logical", "non_positive_duration", "trip_days", "trip_days <= 0")
  valid_coord <- !is.na(lat) & !is.na(lon) & lat >= -90 & lat <= 90 &
    lon >= -180 & lon <= 180
  emit(valid_coord & .land_hits(lat, lon, ref$land),
       "logical", "vessel_on_land", "latitude/longitude",
       "coordinate falls on a landmass")
  emit(!is.na(total) & abs(total - sp_sum) > pmax(1, 0.01 * sp_sum),
       "logical", "catch_total_mismatch", "catch_total_kg",
       "catch_total_kg does not equal the sum of species weights (check decimal)")
  emit(df$effort_unit == "HOOKS" & !is.na(eff) & eff > 0 &
         (sp_sum / eff) > thr(ref, "MAX_CPUE_KG_PER_HOOK"),
       "logical", "implausible_cpue", "effort_amount",
       "catch-per-hook above plausible ceiling")
  hold <- ref$registry$hold_capacity_mt[match(df$vessel_id, ref$registry$vessel_id)]
  emit(!is.na(hold) & (sp_sum / 1000) > hold,
       "logical", "exceeds_hold_capacity", "catch_total_kg",
       "total catch exceeds the vessel's hold capacity")
  if (!is.null(history) && nrow(history)) {
    key  <- paste(df$trip_id, df$vessel_id)
    hkey <- paste(history$trip_id, history$vessel_id)
    emit(key %in% hkey, "logical", "duplicate_in_history", "trip_id",
         "trip already recorded in TUFMAN 2 (merge or update)")

    # overlapping logsheets: a DIFFERENT trip for the same vessel whose date
    # range overlaps. (Mirrors db.R's SQL query; see mirror_find_overlaps().)
    hs <- suppressWarnings(as.Date(history$set_date))
    htd <- to_num(history$trip_days); htd[is.na(htd)] <- 1
    he <- hs + abs(htd)
    rs <- suppressWarnings(as.Date(df$set_date)); re <- rs + ifelse(is.na(td), 0, abs(td))
    overlap <- vapply(seq_len(nrow(df)), function(i) {
      if (is.na(rs[i])) return(FALSE)
      any(history$vessel_id == df$vessel_id[i] & history$trip_id != df$trip_id[i] &
            !is.na(hs) & rs[i] <= he & hs <= re[i])
    }, logical(1))
    emit(overlap, "logical", "overlapping_logsheet", "set_date",
         "trip dates overlap another trip already recorded for this vessel")
  }
  emit(df$trip_id %in% df$trip_id[duplicated(df$trip_id)],
       "logical", "duplicate_logsheet", "trip_id",
       "trip_id duplicated within this submission")

  # ---- compliance ----
  emit(df$effort_unit == "HOOKS" & !is.na(eff) & eff > thr(ref, "MAX_HOOKS_PER_SET"),
       "compliance", "effort_over_guideline", "effort_amount",
       "hooks per set exceeds the regional effort guideline")
  f
}

# --- Size composition --------------------------------------------------------
validate_size_composition <- function(df, ref) {
  cat <- "size_composition"; id <- "sample_id"
  ids <- if (id %in% names(df)) as.character(df[[id]]) else as.character(seq_len(nrow(df)))
  f <- new_findings()
  emit <- function(cond, tier, rule, field = NA_character_, msg = "") {
    cond[is.na(cond)] <- FALSE
    idx <- which(cond)
    if (length(idx))
      f <<- bind_rows(f, finding(cat, ids[idx], idx, tier, rule, field, msg))
  }
  for (col in required_fields(cat)) {
    if (col %in% names(df))
      emit(is_blank(df[[col]]), "structural", "mandatory_field_missing", col,
           paste0(col, " is missing"))
  }
  emit(!(df$sex %in% c("M", "F", "U")),
       "structural", "invalid_code", "sex", "sex not in {M, F, U}")
  emit(!(df$species_code %in% ref$species$species_code),
       "structural", "invalid_code", "species_code", "species_code not in reference")
  L <- to_num(df$length_cm); W <- to_num(df$weight_kg)
  m <- match(df$species_code, ref$species$species_code)
  lmax <- ref$species$lmax_cm[m]; a <- ref$species$lw_a[m]; b <- ref$species$lw_b[m]
  emit(!is.na(L) & !is.na(lmax) & lmax > 0 & L > lmax,
       "logical", "length_over_lmax", "length_cm",
       "length exceeds the species maximum")
  pred <- a * (L^b)
  emit(!is.na(L) & !is.na(W) & !is.na(a) & a > 0 & pred > 0 &
         abs(W - pred) / pred > thr(ref, "WEIGHT_AT_LENGTH_TOL"),
       "logical", "weight_at_length", "weight_kg",
       "weight implausible for the recorded length")
  f
}

# --- Observer / bycatch ------------------------------------------------------
validate_observer_bycatch <- function(df, ref, effort = NULL) {
  cat <- "observer_bycatch"; id <- "observation_id"
  ids <- if (id %in% names(df)) as.character(df[[id]]) else as.character(seq_len(nrow(df)))
  f <- new_findings()
  emit <- function(cond, tier, rule, field = NA_character_, msg = "") {
    cond[is.na(cond)] <- FALSE
    idx <- which(cond)
    if (length(idx))
      f <<- bind_rows(f, finding(cat, ids[idx], idx, tier, rule, field, msg))
  }
  for (col in required_fields(cat)) {
    if (col %in% names(df))
      emit(is_blank(df[[col]]), "structural", "mandatory_field_missing", col,
           paste0(col, " is missing"))
  }
  emit(!(df$species_code %in% ref$species$species_code),
       "structural", "invalid_code", "species_code", "species_code not in reference")
  cnt <- to_num(df$count)
  emit(!is.na(cnt) & cnt < 0, "logical", "negative_count", "count", "count < 0")
  m <- match(df$species_code, ref$species$species_code)
  prot <- ref$species$is_protected[m]; grp <- ref$species$species_group[m]
  emit(!is.na(prot) & prot == 1,
       "compliance", "protected_species_interaction", "species_code",
       "interaction with a protected species (review required)")

  # shark bycatch rate per 1000 hooks, using catch-effort hooks for the trip
  if (!is.null(effort) && nrow(effort)) {
    hooks <- effort %>%
      mutate(eff = to_num(.data$effort_amount)) %>%
      filter(.data$effort_unit == "HOOKS") %>%
      group_by(trip_id) %>% summarise(hooks = sum(eff, na.rm = TRUE), .groups = "drop")
    sharks <- tibble(trip_id = df$trip_id, grp = grp,
                     cnt = ifelse(is.na(cnt), 0, cnt)) %>%
      filter(grp == "shark", cnt > 0) %>%
      group_by(trip_id) %>% summarise(sharks = sum(cnt), .groups = "drop")
    over <- sharks %>% left_join(hooks, by = "trip_id") %>%
      mutate(rate = ifelse(!is.na(hooks) & hooks > 0, sharks / hooks * 1000, NA)) %>%
      filter(!is.na(rate) & rate > thr(ref, "MAX_SHARK_BYCATCH_RATE"))
    for (k in seq_len(nrow(over))) {
      tp <- over$trip_id[k]
      rw <- which(df$trip_id == tp)[1]
      f <- bind_rows(f, finding(cat, tp, rw, "compliance",
        "shark_bycatch_over_threshold", "count",
        sprintf("shark bycatch %.1f per 1000 hooks exceeds threshold", over$rate[k])))
    }
  }
  f
}

# --- Longline E-Monitoring: excessive speed between events -------------------
validate_em_longline <- function(df, ref) {
  cat <- "em_longline"; id <- "trip_id"
  f <- new_findings()
  for (col in required_fields(cat)) {
    if (col %in% names(df)) {
      idx <- which(is_blank(df[[col]]))
      if (length(idx))
        f <- bind_rows(f, finding(cat, df$trip_id[idx], idx, "structural",
          "mandatory_field_missing", col, paste0(col, " is missing")))
    }
  }
  df2 <- df %>% mutate(.row = row_number(),
                       lat = to_num(latitude), lon = to_num(longitude),
                       seq = to_num(event_seq),
                       t = as.POSIXct(event_time, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  vmax <- ref$registry$max_speed_kn[match(df2$vessel_id, ref$registry$vessel_id)]
  df2$vmax <- ifelse(is.na(vmax), 20, vmax)
  for (tp in unique(df2$trip_id)) {
    sub <- df2 %>% filter(trip_id == tp) %>% arrange(seq)
    if (nrow(sub) < 2) next
    for (i in 2:nrow(sub)) {
      hrs <- as.numeric(difftime(sub$t[i], sub$t[i - 1], units = "hours"))
      if (is.na(hrs) || hrs <= 0) next
      nm <- haversine_nm(sub$lat[i - 1], sub$lon[i - 1], sub$lat[i], sub$lon[i])
      if (!is.na(nm) && nm / hrs > sub$vmax[i]) {
        f <- bind_rows(f, finding(cat, tp, sub$.row[i], "logical",
          "excessive_speed", "latitude/longitude",
          sprintf("implied speed %.0f kn exceeds max %.0f kn", nm / hrs, sub$vmax[i])))
        break
      }
    }
  }
  # multiple in-port: two In-Port (activity_id == 6) events too far apart to be
  # the same docking event (a vessel can't be at two distant ports at once)
  if ("activity_id" %in% names(df)) {
    ip <- df2 %>% filter(to_num(activity_id) == 6)
    for (tp in unique(ip$trip_id)) {
      sub <- ip %>% filter(trip_id == tp)
      if (nrow(sub) < 2) next
      far <- FALSE
      for (i in 1:(nrow(sub) - 1)) for (k in (i + 1):nrow(sub))
        if (!is.na(haversine_nm(sub$lat[i], sub$lon[i], sub$lat[k], sub$lon[k])) &&
            haversine_nm(sub$lat[i], sub$lon[i], sub$lat[k], sub$lon[k]) > 50) far <- TRUE
      if (far)
        f <- bind_rows(f, finding(cat, tp, sub$.row[1], "logical",
          "multiple_in_port", "activity_id",
          "two In-Port events at distant locations on the same day"))
    }
  }
  f
}

# --- dispatcher + summaries --------------------------------------------------
validate_submission <- function(df, category, ref, context = list()) {
  f <- switch(category,
    catch_effort     = validate_catch_effort(df, ref, history = context$history),
    size_composition = validate_size_composition(df, ref),
    observer_bycatch = validate_observer_bycatch(df, ref, effort = context$effort),
    em_longline      = validate_em_longline(df, ref),
    stop("unknown category: ", category))
  if (!nrow(f)) return(mutate(f, severity = character()))
  f %>% mutate(severity = unname(SEVERITY[tier])) %>% arrange(row, tier)
}

submission_status <- function(findings, n_rows) {
  n_err  <- sum(findings$severity == "error")
  n_warn <- sum(findings$severity == "warning")
  flagged <- length(unique(findings$row))
  list(n_rows = n_rows, n_error = n_err, n_warning = n_warn,
       flagged_rows = flagged, clean_rows = n_rows - flagged,
       can_forward = n_err == 0)
}
