# =============================================================================
# tufman.R  --  the conditional forward to TUFMAN 2 (mocked, stateless)
# -----------------------------------------------------------------------------
# The gateway pattern: only a submission with ZERO blocking errors may be pushed
# to TUFMAN 2. Authentication is the documented two-step (obtain a scoped token,
# then POST the payload). Here both steps are mocked so the workflow can be
# demonstrated offline; swap `TUFMAN2$base`/the httr call for the real endpoint.
#
# Stateless by design: nothing is persisted -- the payload is built, forwarded
# (or held), and discarded, honouring the WCPFC data-protection (RAP) posture.
# =============================================================================

TUFMAN2 <- list(
  base = Sys.getenv("TUFMAN2_BASE", "https://tufman2.example.spc.int/api/v2"),
  token_path = "/auth/token",
  submit_path = "/logsheets",
  # live mode performs real HTTP via httr; default is the offline mock so the
  # appliance demonstrates the workflow without a reachable endpoint.
  live = identical(Sys.getenv("TUFMAN2_LIVE"), "true")
)

# Step 1 -- exchange country credentials for a scoped token.
# Live: POST credentials to the token endpoint. Mock: synthesise a scoped token.
tufman2_token <- function(country_code, credentials = NULL) {
  if (isTRUE(TUFMAN2$live) && requireNamespace("httr", quietly = TRUE)) {
    resp <- httr::POST(paste0(TUFMAN2$base, TUFMAN2$token_path),
                       body = c(list(country = country_code), credentials),
                       encode = "json")
    body <- httr::content(resp, as = "parsed")
    return(list(country = country_code, token = body$access_token,
                scope = body$scope, expires_in = body$expires_in,
                http_status = httr::status_code(resp)))
  }
  list(country = country_code,
       token = paste0("mock-", country_code, "-",
                      substr(gsub("[^0-9]", "", format(Sys.time(), "%H%M%OS3")), 1, 8)),
       scope = paste0("logsheets:write country:", country_code),
       expires_in = 3600)
}

# Build a TUFMAN 2 submission envelope from a validated catch_effort trip.
build_tufman2_envelope <- function(trip_row, status, country_code) {
  list(
    submission_metadata = list(
      country_code = country_code,
      submission_date = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      validation_status = if (isTRUE(status$can_forward)) "PASSED" else "HELD",
      blocking_errors = status$n_error,
      warnings = status$n_warning
    ),
    logsheet_data = list(
      trip_id = trip_row$trip_id,
      vessel_id = trip_row$vessel_id,
      trip_start = trip_row$set_date,
      coordinates = list(lat = trip_row$latitude, lon = trip_row$longitude),
      catch = list(
        list(species = "SKJ", weight_mt = round((trip_row$catch_skj_kg %||% 0) / 1000, 3)),
        list(species = "YFT", weight_mt = round((trip_row$catch_yft_kg %||% 0) / 1000, 3)),
        list(species = "BET", weight_mt = round((trip_row$catch_bet_kg %||% 0) / 1000, 3)),
        list(species = "ALB", weight_mt = round((trip_row$catch_alb_kg %||% 0) / 1000, 3))
      )
    )
  )
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || is.na(a)) b else a

# Step 2 -- conditional forward. Returns the simulated TUFMAN 2 response.
forward_to_tufman2 <- function(status, envelope, token) {
  if (!isTRUE(status$can_forward)) {
    return(list(forwarded = FALSE, http_status = 409,
                message = sprintf("HELD: %d blocking error(s) must be fixed before submission.",
                                  status$n_error)))
  }
  if (isTRUE(TUFMAN2$live) && requireNamespace("httr", quietly = TRUE)) {
    resp <- httr::POST(paste0(TUFMAN2$base, TUFMAN2$submit_path),
                       httr::add_headers(Authorization = paste("Bearer", token$token)),
                       body = envelope, encode = "json")
    body <- httr::content(resp, as = "parsed")
    return(list(forwarded = httr::status_code(resp) %in% c(200, 201),
                http_status = httr::status_code(resp),
                guid = body$guid %||% NA_character_,
                message = paste("TUFMAN 2 responded:", httr::status_code(resp)),
                scope = token$scope))
  }
  guid <- paste0(format(Sys.time(), "%Y%m%d"), "-",
                 paste(sample(c(0:9, letters[1:6]), 8, TRUE), collapse = ""))
  list(forwarded = TRUE, http_status = 201, guid = guid,
       message = sprintf("ACCEPTED by TUFMAN 2 (mock). Report GUID: %s", guid),
       scope = token$scope)
}
