# =============================================================================
# schemas.R  --  the canonical field contract per data category
# -----------------------------------------------------------------------------
# These specs drive (a) structural validation, (b) the smart column auto-mapper,
# and (c) the CSV templates. They mirror the WCPFC data categories (catch &
# effort, size composition, observer/bycatch) and the TUFMAN 2 logsheet / EM
# longline JSON intent. Swap field names here to track the official SciData /
# TUFMAN2 JSON standard exactly.
# =============================================================================

# Each column: required, type (character|numeric|integer|date|enum|coord_lat|
# coord_lon), optional `enum`, and `aliases` the auto-mapper recognises from
# non-standard spreadsheets.
GK_SCHEMAS <- list(
  catch_effort = list(
    id_field = "trip_id",
    label = "Catch & Effort logsheet",
    fields = list(
      trip_id        = list(required = TRUE,  type = "character", aliases = c("trip", "logsheet_id", "trip_no")),
      vessel_id      = list(required = TRUE,  type = "character", aliases = c("vessel", "vesselid", "ves_id")),
      flag           = list(required = TRUE,  type = "character", aliases = c("flag_state", "ccm", "country")),
      gear_code      = list(required = TRUE,  type = "enum", enum = c("LL", "PS", "PL"), aliases = c("gear", "method")),
      set_date       = list(required = TRUE,  type = "date", aliases = c("date", "fishing_date", "set_dt")),
      trip_days      = list(required = TRUE,  type = "numeric", aliases = c("days", "trip_duration", "duration_days")),
      latitude       = list(required = TRUE,  type = "coord_lat", aliases = c("lat", "y", "latitude_dd")),
      longitude      = list(required = TRUE,  type = "coord_lon", aliases = c("lon", "lng", "x", "longitude_dd")),
      effort_unit    = list(required = TRUE,  type = "enum", enum = c("HOOKS", "SETS", "DAYS"), aliases = c("eff_unit", "unit")),
      effort_amount  = list(required = TRUE,  type = "numeric", aliases = c("effort", "hooks", "sets", "eff")),
      target_species = list(required = TRUE,  type = "character", aliases = c("target", "tgt_sp")),
      catch_skj_kg   = list(required = FALSE, type = "numeric", aliases = c("skj", "skipjack_kg")),
      catch_yft_kg   = list(required = FALSE, type = "numeric", aliases = c("yft", "yellowfin_kg")),
      catch_bet_kg   = list(required = FALSE, type = "numeric", aliases = c("bet", "bigeye_kg")),
      catch_alb_kg   = list(required = FALSE, type = "numeric", aliases = c("alb", "albacore_kg")),
      catch_total_kg = list(required = TRUE,  type = "numeric", aliases = c("total_catch", "total_kg", "catch_total"))
    )
  ),
  size_composition = list(
    id_field = "sample_id",
    label = "Size composition",
    fields = list(
      sample_id    = list(required = TRUE, type = "character", aliases = c("sample", "fish_id")),
      trip_id      = list(required = TRUE, type = "character", aliases = c("trip", "logsheet_id")),
      species_code = list(required = TRUE, type = "character", aliases = c("species", "sp_code")),
      length_cm    = list(required = TRUE, type = "numeric", aliases = c("length", "len", "fork_length")),
      weight_kg    = list(required = FALSE, type = "numeric", aliases = c("weight", "wt", "wgt")),
      sex          = list(required = TRUE, type = "enum", enum = c("M", "F", "U"), aliases = c("gender")),
      measure_date = list(required = TRUE, type = "date", aliases = c("date", "sample_date"))
    )
  ),
  observer_bycatch = list(
    id_field = "observation_id",
    label = "Observer / bycatch",
    fields = list(
      observation_id   = list(required = TRUE, type = "character", aliases = c("obs_id", "event_id")),
      trip_id          = list(required = TRUE, type = "character", aliases = c("trip", "logsheet_id")),
      set_date         = list(required = TRUE, type = "date", aliases = c("date")),
      latitude         = list(required = TRUE, type = "coord_lat", aliases = c("lat", "y")),
      longitude        = list(required = TRUE, type = "coord_lon", aliases = c("lon", "lng", "x")),
      species_code     = list(required = TRUE, type = "character", aliases = c("species", "sp_code")),
      species_group    = list(required = TRUE, type = "enum", enum = c("tuna", "shark", "turtle", "seabird", "mammal", "billfish", "other"), aliases = c("group")),
      interaction_type = list(required = TRUE, type = "character", aliases = c("interaction", "event")),
      condition        = list(required = TRUE, type = "character", aliases = c("fate", "status")),
      count            = list(required = TRUE, type = "integer", aliases = c("n", "number", "qty"))
    )
  ),
  em_longline = list(
    id_field = "trip_id",
    label = "Longline E-Monitoring event stream",
    fields = list(
      trip_id    = list(required = TRUE, type = "character", aliases = c("trip", "logsheet_id")),
      vessel_id  = list(required = TRUE, type = "character", aliases = c("vessel")),
      event_seq  = list(required = TRUE, type = "integer", aliases = c("seq", "order")),
      event_time = list(required = TRUE, type = "character", aliases = c("timestamp", "time", "datetime")),
      event_type = list(required = TRUE, type = "character", aliases = c("type", "activity")),
      latitude   = list(required = TRUE, type = "coord_lat", aliases = c("lat", "y")),
      longitude  = list(required = TRUE, type = "coord_lon", aliases = c("lon", "lng", "x"))
    )
  )
)

schema_fields <- function(category) names(GK_SCHEMAS[[category]]$fields)
required_fields <- function(category) {
  f <- GK_SCHEMAS[[category]]$fields
  names(f)[map_lgl(f, ~ isTRUE(.x$required))]
}
