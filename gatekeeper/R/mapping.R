# =============================================================================
# mapping.R  --  smart column auto-mapper + TUFMAN 2 Longline JSON ingest
# -----------------------------------------------------------------------------
# Two jobs:
#  (1) automap_columns(): when a country uploads a non-standard CSV/Excel, match
#      its headers to the canonical schema using the per-field aliases, so a
#      messy spreadsheet can be lined up to the standard before validation.
#  (2) the TUFMAN 2 Longline JSON path: validate a payload against the LL JSON
#      contract (ISO 6709 coords, FAO codes, the activity_id==1 conditional, the
#      catch anyOf rule) and FLATTEN it to the tabular catch_effort grain so the
#      same logical/compliance engine runs on JSON and CSV alike.
# =============================================================================
suppressPackageStartupMessages(library(jsonlite))

# ---- (1) smart column auto-mapper ------------------------------------------
automap_columns <- function(df, category) {
  spec <- GK_SCHEMAS[[category]]$fields
  canon <- names(spec)
  have <- names(df)
  norm <- function(x) tolower(gsub("[^a-z0-9]", "", tolower(x)))
  have_norm <- norm(have)
  mapping <- tibble(canonical = character(), source = character(),
                    how = character())
  used <- rep(FALSE, length(have))
  for (cf in canon) {
    cand <- c(cf, spec[[cf]]$aliases)
    hit <- which(have_norm %in% norm(cand) & !used)
    if (length(hit)) {
      mapping <- bind_rows(mapping, tibble(canonical = cf,
        source = have[hit[1]], how = if (have[hit[1]] == cf) "exact" else "alias"))
      used[hit[1]] <- TRUE
    }
  }
  out <- df
  ren <- setNames(mapping$source, mapping$canonical)
  ren <- ren[ren != names(ren)]
  if (length(ren)) out <- dplyr::rename(out, !!!ren)
  missing_required <- setdiff(required_fields(category), c(mapping$canonical))
  list(data = out, mapping = mapping, missing_required = missing_required)
}

# ---- (2) TUFMAN 2 LL JSON: ISO 6709 coordinate decoding --------------------
# lat  "+DDMM.MMM"  (deg_digits = 2);  lon "+DDDMM.MMM" (deg_digits = 3)
iso6709_to_dd <- function(s, deg_digits) {
  s <- as.character(s)
  out <- rep(NA_real_, length(s))
  ok <- grepl(sprintf("^[+-][0-9]{%d}[0-9]{2}\\.[0-9]{3}$", deg_digits), s)
  for (i in which(ok)) {
    sign <- if (substr(s[i], 1, 1) == "-") -1 else 1
    body <- substr(s[i], 2, nchar(s[i]))
    deg  <- as.numeric(substr(body, 1, deg_digits))
    minutes <- as.numeric(substr(body, deg_digits + 1, nchar(body)))
    out[i] <- round(sign * (deg + minutes / 60), 5)
  }
  out
}
.lat_pat <- "^[+-][0-9]{4}\\.[0-9]{3}$"
.lon_pat <- "^[+-][0-9]{5}\\.[0-9]{3}$"
.fao_pat <- "^[A-Z]{3}$"
.port_pat <- "^[A-Z]{5}$"
.iso8601_pat <- "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:?[0-9]{2})$"
ACTIVITY_ENUM <- c(1, 3, 4, 5, 6, 18)

# Validate a parsed TUFMAN 2 LL document against the JSON contract.
# Returns findings (tier "structural", category "tufman2_ll", record_id = path).
validate_tufman2_ll <- function(doc) {
  f <- new_findings()
  add <- function(path, rule, msg)
    f <<- bind_rows(f, finding("tufman2_ll", path, NA, "structural", rule,
                               NA_character_, msg))

  trip_required <- c("trip_id", "license", "vessel_identification",
                     "vessel_captain", "sp_code_target", "depart_port",
                     "depart_datetime", "ll_activities")
  for (k in trip_required)
    if (is.null(doc[[k]])) add("(trip)", "missing_required_property",
                               paste0("missing required property: ", k))

  if (!is.null(doc$sp_code_target) && !grepl(.fao_pat, doc$sp_code_target))
    add("sp_code_target", "pattern", "target species must be a 3-letter FAO code")
  if (!is.null(doc$depart_port) && !grepl(.port_pat, doc$depart_port))
    add("depart_port", "pattern", "depart_port must be a 5-letter location code")
  if (!is.null(doc$unload_port) && !grepl(.port_pat, doc$unload_port))
    add("unload_port", "pattern", "unload_port must be a 5-letter location code")
  if (!is.null(doc$depart_datetime) && !grepl(.iso8601_pat, doc$depart_datetime))
    add("depart_datetime", "format", "depart_datetime must be ISO 8601 UTC")
  if (is.null(doc$vessel_identification$wcpfc_vid))
    add("vessel_identification", "missing_required_property", "wcpfc_vid is required")

  acts <- doc$ll_activities
  if (!is.null(acts)) {
    if (is.data.frame(acts)) acts <- split(acts, seq_len(nrow(acts)))
    for (i in seq_along(acts)) {
      a <- as.list(acts[[i]]); p <- paste0("ll_activities/", i - 1)
      for (k in c("activity_id", "act_datetime", "lat", "lon"))
        if (is.null(a[[k]]) || (length(a[[k]]) == 1 && is.na(a[[k]])))
          add(p, "missing_required_property", paste0("missing required: ", k))
      if (!is.null(a$activity_id) && !(a$activity_id %in% ACTIVITY_ENUM))
        add(p, "enum", "activity_id not in {1,3,4,5,6,18}")
      if (!is.null(a$lat) && !grepl(.lat_pat, a$lat))
        add(paste0(p, "/lat"), "pattern", "lat must be ISO 6709 +/-DDMM.MMM")
      if (!is.null(a$lon) && !grepl(.lon_pat, a$lon))
        add(paste0(p, "/lon"), "pattern", "lon must be ISO 6709 +/-DDDMM.MMM")
      if (!is.null(a$act_datetime) && !grepl(.iso8601_pat, a$act_datetime))
        add(paste0(p, "/act_datetime"), "format", "act_datetime must be ISO 8601")
      # conditional: activity_id == 1 (Fishing Set) requires hooks config + catches
      if (!is.null(a$activity_id) && a$activity_id == 1) {
        for (k in c("hk_btwn_flt", "hooks", "ll_catches"))
          if (is.null(a[[k]]))
            add(p, "conditional_required",
                paste0("Fishing Set (activity_id=1) requires: ", k))
        catches <- a$ll_catches
        if (!is.null(catches)) {
          if (is.data.frame(catches)) catches <- split(catches, seq_len(nrow(catches)))
          for (j in seq_along(catches)) {
            cobj <- as.list(catches[[j]]); cp <- paste0(p, "/ll_catches/", j - 1)
            if (is.null(cobj$sp_code_ret) || !grepl(.fao_pat, cobj$sp_code_ret))
              add(paste0(cp, "/sp_code_ret"), "pattern", "sp_code_ret must be 3-letter FAO code")
            has_ret  <- !is.null(cobj$sp_ret_no)  && !is.na(cobj$sp_ret_no)
            has_disc <- !is.null(cobj$sp_disc_no) && !is.na(cobj$sp_disc_no)
            if (!has_ret && !has_disc)
              add(cp, "anyOf", "each catch must provide sp_ret_no or sp_disc_no")
          }
        }
      }
    }
  }
  if (nrow(f)) f$severity <- "error"
  f
}

# Flatten a valid LL document to the catch_effort grain (one row per Fishing Set)
# so the shared logical/compliance engine can run on JSON submissions too.
tufman2_ll_to_catch_effort <- function(doc, registry = NULL) {
  acts <- doc$ll_activities
  if (is.null(acts)) return(tibble())
  if (is.data.frame(acts)) acts <- split(acts, seq_len(nrow(acts)))
  vid <- doc$vessel_identification$wcpfc_vid
  vessel_id <- paste0("WCPFC-", vid)
  flag <- if (!is.null(registry))
    registry$flag[match(vessel_id, registry$vessel_id)][1] else NA_character_
  # trip duration (days) from the trip header, when a return datetime is present
  trip_days <- if (!is.null(doc$unload_datetime) && !is.null(doc$depart_datetime))
    as.numeric(as.Date(substr(doc$unload_datetime, 1, 10)) -
               as.Date(substr(doc$depart_datetime, 1, 10))) else NA_real_
  rows <- list()
  for (a in acts) {
    a <- as.list(a)
    if (is.null(a$activity_id) || a$activity_id != 1) next
    catches <- a$ll_catches
    if (is.data.frame(catches)) catches <- split(catches, seq_len(nrow(catches)))
    kg <- function(code) {
      tot <- 0
      for (cobj in catches) {
        cobj <- as.list(cobj)
        if (!is.null(cobj$sp_code_ret) && cobj$sp_code_ret == code)
          tot <- tot + (if (!is.null(cobj$sp_ret_mt)) cobj$sp_ret_mt else 0) * 1000
      }
      tot
    }
    skj <- kg("SKJ"); yft <- kg("YFT"); bet <- kg("BET"); alb <- kg("ALB")
    rows[[length(rows) + 1]] <- tibble(
      trip_id = doc$trip_id, vessel_id = vessel_id, flag = flag,
      gear_code = "LL",
      set_date = substr(a$act_datetime, 1, 10),
      trip_days = trip_days,
      latitude = iso6709_to_dd(a$lat, 2),
      longitude = iso6709_to_dd(a$lon, 3),
      effort_unit = "HOOKS", effort_amount = if (!is.null(a$hooks)) a$hooks else NA,
      target_species = doc$sp_code_target,
      catch_skj_kg = skj, catch_yft_kg = yft, catch_bet_kg = bet, catch_alb_kg = alb,
      catch_total_kg = skj + yft + bet + alb)
  }
  if (!length(rows)) tibble() else bind_rows(rows)
}

# Convenience: read a JSON file, validate, and (if clean) flatten.
ingest_tufman2_ll <- function(path, registry = NULL) {
  doc <- jsonlite::fromJSON(path, simplifyVector = TRUE, simplifyDataFrame = FALSE)
  schema_findings <- validate_tufman2_ll(doc)
  tab <- if (!nrow(schema_findings)) tufman2_ll_to_catch_effort(doc, registry) else tibble()
  list(doc = doc, schema_findings = schema_findings, table = tab)
}
