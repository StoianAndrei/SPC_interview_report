# =============================================================================
# db.R  --  lightweight SQL mirror of TUFMAN 2 (duplicate / overlap queries)
# -----------------------------------------------------------------------------
# The production design calls for a small relational DB that mirrors TUFMAN 2's
# structural rules, so "duplicate trip" and "overlapping logsheet" checks run
# instantly. This module builds that mirror in SQLite from the history CSV and
# exposes the equivalent queries. It is OPTIONAL: the in-engine checks in
# validate.R reproduce the same logic without a DB, so the gateway still runs if
# RSQLite is not installed. A Python/Node controller would point the Plumber API
# at the real Postgres/SQL Server mirror instead.
# =============================================================================

mirror_available <- function() requireNamespace("RSQLite", quietly = TRUE) &&
  requireNamespace("DBI", quietly = TRUE)

# Build the mirror from the history data frame. Returns a DBI connection.
mirror_connect <- function(history, path = ":memory:") {
  if (!mirror_available())
    stop("RSQLite/DBI not installed; the in-engine checks in validate.R cover the same logic.")
  con <- DBI::dbConnect(RSQLite::SQLite(), path)
  h <- history %>%
    mutate(start_date = as.character(as.Date(set_date)),
           end_date = as.character(as.Date(set_date) +
                                     ifelse(is.na(to_num(trip_days)), 1, abs(to_num(trip_days)))))
  DBI::dbWriteTable(con, "trips", as.data.frame(h), overwrite = TRUE)
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS ix_vessel ON trips(vessel_id)")
  con
}

# Does this exact trip already exist for the vessel? (duplicate)
mirror_trip_exists <- function(con, trip_id, vessel_id) {
  q <- "SELECT COUNT(*) n FROM trips WHERE trip_id = ? AND vessel_id = ?"
  DBI::dbGetQuery(con, q, params = list(trip_id, vessel_id))$n > 0
}

# Any DIFFERENT trip for this vessel whose [start,end] overlaps [start,end]?
mirror_find_overlaps <- function(con, vessel_id, start_date, end_date, trip_id) {
  q <- "SELECT trip_id FROM trips
         WHERE vessel_id = ? AND trip_id <> ?
           AND date(start_date) <= date(?) AND date(?) <= date(end_date)"
  DBI::dbGetQuery(con, q, params = list(vessel_id, trip_id, end_date, start_date))$trip_id
}

# Append an accepted submission to the mirror (so later uploads see it).
mirror_record <- function(con, trip_id, vessel_id, set_date, trip_days) {
  end <- as.character(as.Date(set_date) + abs(as.numeric(trip_days)))
  DBI::dbExecute(con,
    "INSERT INTO trips (trip_id, vessel_id, set_date, trip_days, start_date, end_date)
     VALUES (?,?,?,?,?,?)",
    params = list(trip_id, vessel_id, as.character(set_date), trip_days,
                  as.character(as.Date(set_date)), end))
}
