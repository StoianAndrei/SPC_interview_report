# =============================================================================
# health.R  --  the data-completeness "health score"
# -----------------------------------------------------------------------------
# Turns a submission into a single 0-100 gauge plus a plain-language breakdown,
# e.g. "92% complete, but historical size-data gaps in Q3" -- the persistent
# data-gap problem the WCPFC Scientific Committee flags every year.
# =============================================================================

# share of required cells that are populated
field_completeness <- function(df, category) {
  req <- intersect(required_fields(category), names(df))
  if (!length(req) || !nrow(df)) return(0)
  filled <- sum(map_int(req, ~ sum(!is_blank(df[[.x]]))))
  filled / (length(req) * nrow(df))
}

# quarters covered vs the four expected (temporal completeness)
temporal_coverage <- function(df) {
  date_col <- intersect(c("set_date", "measure_date"), names(df))
  if (!length(date_col)) return(list(coverage = 1, gaps = character()))
  d <- suppressWarnings(as.Date(df[[date_col[1]]], format = "%Y-%m-%d"))
  q <- ceiling(as.integer(format(d, "%m")) / 3)
  q <- q[!is.na(q)]
  present <- sort(unique(q))
  gaps <- setdiff(1:4, present)
  list(coverage = length(present) / 4,
       gaps = if (length(gaps)) paste0("Q", gaps) else character())
}

health_score <- function(df, category, findings) {
  n <- nrow(df)
  comp <- field_completeness(df, category)
  flagged <- if (nrow(findings)) length(unique(findings$row[!is.na(findings$row)])) else 0
  validity <- if (n) (n - flagged) / n else 0
  temp <- temporal_coverage(df)
  score <- round(100 * (0.45 * comp + 0.35 * validity + 0.20 * temp$coverage))

  messages <- character()
  messages <- c(messages, sprintf("%.0f%% of required fields are complete.", 100 * comp))
  if (validity < 1)
    messages <- c(messages, sprintf("%d of %d records were flagged for review.", flagged, n))
  if (length(temp$gaps))
    messages <- c(messages, sprintf("Temporal gap: no records in %s.",
                                    paste(temp$gaps, collapse = ", ")))
  if (!length(messages)) messages <- "All checks clean."

  breakdown <- tibble(
    component = c("Field completeness", "Record validity", "Temporal coverage"),
    weight = c(0.45, 0.35, 0.20),
    value = round(100 * c(comp, validity, temp$coverage))
  )
  list(score = score, breakdown = breakdown, messages = messages,
       grade = cut(score, c(-1, 50, 75, 90, 101),
                   labels = c("At risk", "Fair", "Good", "Excellent")))
}
