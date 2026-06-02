# =============================================================================
# agent.R  --  the Edge "Data Archaeologist" mapping agent (LLM-optional)
# -----------------------------------------------------------------------------
# The political win: this runs entirely on a country's own machine (the Edge
# appliance) so raw data never leaves the building. The agent removes the
# data-mapping bottleneck:
#
#   Step 1  DISCOVERY   : interpret messy / multilingual headers + free-text
#                         species names (e.g. Spanish "Fecha" -> set_date,
#                         "Atun ojo grande" -> BET).
#   Step 2  TRANSLATION : line the file up to the standard schema. Values are
#                         mapped with deterministic dictionaries (no LLM
#                         hallucination of catch weights); an LLM, if present,
#                         only PROPOSES column mappings, which a human approves.
#   Step 3  FLAGGING    : turn technical rule failures into plain, supportive
#                         language for a non-specialist data officer.
#
# Design rule: everything works WITHOUT a model. A local LLM (via Ollama /
# ellmer) is a pluggable enhancement, never a hard dependency — so the appliance
# runs on a modest offline machine.
# =============================================================================

# accent-folding normaliser so "Atún" matches "atun", "Fecha" matches "fecha"
.fold <- function(x) {
  x <- tolower(as.character(x))
  x <- iconv(x, to = "ASCII//TRANSLIT")
  x <- gsub("[^a-z0-9]+", " ", x)
  trimws(x)
}

# ---- dictionaries -----------------------------------------------------------
load_field_synonyms <- function(dir = GK_PATHS$reference) {
  p <- file.path(dir, "field_synonyms.csv")
  if (!file.exists(p)) return(tibble(canonical = character(), synonym = character(), lang = character()))
  readr::read_csv(p, show_col_types = FALSE, progress = FALSE)
}
load_species_synonyms <- function(dir = GK_PATHS$reference) {
  p <- file.path(dir, "species_synonyms.csv")
  if (!file.exists(p)) return(tibble(fao_code = character(), name = character(), lang = character()))
  readr::read_csv(p, show_col_types = FALSE, progress = FALSE)
}

# Step 1+2 (deterministic core): map a messy file's headers to the schema using
# field aliases + the multilingual synonym dictionary.
archaeologist_map <- function(df, category, field_syn = load_field_synonyms()) {
  spec <- GK_SCHEMAS[[category]]$fields
  canon <- names(spec)
  syn_lookup <- field_syn %>% mutate(key = .fold(synonym))
  have <- names(df); have_key <- .fold(have)
  rows <- list()
  used <- rep(FALSE, length(have))
  for (cf in canon) {
    keys <- unique(c(.fold(cf), .fold(spec[[cf]]$aliases),
                     syn_lookup$key[syn_lookup$canonical == cf]))
    hit <- which(have_key %in% keys & !used)
    if (length(hit)) {
      lang <- syn_lookup$lang[match(have_key[hit[1]], syn_lookup$key)]
      rows[[length(rows) + 1]] <- tibble(
        canonical = cf, source = have[hit[1]],
        how = if (.fold(have[hit[1]]) == .fold(cf)) "exact" else "synonym",
        lang = ifelse(is.na(lang), "en", lang),
        confidence = if (.fold(have[hit[1]]) == .fold(cf)) 1 else 0.85)
      used[hit[1]] <- TRUE
    }
  }
  mapping <- if (length(rows)) bind_rows(rows) else
    tibble(canonical = character(), source = character(), how = character(),
           lang = character(), confidence = double())
  out <- df
  ren <- setNames(mapping$source, mapping$canonical)
  ren <- ren[ren != names(ren)]
  if (length(ren)) out <- dplyr::rename(out, !!!ren)
  list(data = out, mapping = mapping,
       missing_required = setdiff(required_fields(category), mapping$canonical),
       reasoning = .mapping_reasoning(mapping))
}

# free-text species -> FAO code (deterministic; the LLM never invents these)
translate_species <- function(values, sp_syn = load_species_synonyms()) {
  key <- .fold(values)
  out <- sp_syn$fao_code[match(key, .fold(sp_syn$name))]
  ifelse(is.na(out), as.character(values), out)  # leave untouched if unknown
}

.mapping_reasoning <- function(mapping) {
  if (!nrow(mapping)) return("No columns could be matched to the standard.")
  non_en <- mapping %>% filter(lang != "en", how == "synonym")
  bits <- sprintf("'%s' -> %s", mapping$source, mapping$canonical)
  msg <- paste0("Matched ", nrow(mapping), " columns to the SPC standard: ",
                paste(head(bits, 8), collapse = "; "),
                if (nrow(mapping) > 8) " ..." else ".")
  if (nrow(non_en))
    msg <- paste0(msg, "  Recognised non-English headers (",
                  paste(unique(non_en$lang), collapse = "/"), ").")
  msg
}

# ---- Step 3: plain-language flag translation --------------------------------
.PLAIN <- c(
  mandatory_field_missing      = "A required field is blank. Please fill it in before submitting.",
  vessel_not_registered        = "This vessel isn't in the WCPFC registry — check the vessel ID.",
  invalid_code                 = "A code value isn't one of the allowed options — please pick a valid one.",
  coordinate_out_of_range      = "A GPS coordinate is outside the possible range — likely a typo.",
  invalid_date                 = "A date isn't a real calendar date — please check the format (YYYY-MM-DD).",
  impossible_trip_duration     = "The trip length looks impossibly long — please check the dates.",
  non_positive_duration        = "The trip length is zero or negative — please check the dates.",
  vessel_on_land               = "These coordinates put the vessel on land — please review the lat/long.",
  catch_total_mismatch         = "The total catch doesn't equal the species weights added up — check the decimal point.",
  implausible_cpue             = "The catch is far too high for the effort recorded — please double-check.",
  exceeds_hold_capacity        = "The catch is larger than this vessel can physically hold — likely a units/decimal error.",
  duplicate_logsheet           = "This trip appears twice in the file — please remove the duplicate.",
  duplicate_in_history         = "This trip is already in TUFMAN 2 — choose to merge or update instead.",
  excessive_speed              = "The implied vessel speed between two points is impossible — check the times.",
  length_over_lmax             = "A fish length is bigger than the species maximum — please verify.",
  weight_at_length             = "A fish weight doesn't fit its length — please re-check the measurement.",
  effort_over_guideline        = "Effort exceeds the regional guideline — flagged for compliance review.",
  protected_species_interaction= "A protected-species interaction was recorded — this needs review.",
  shark_bycatch_over_threshold = "Shark bycatch on this trip is above the regional threshold — flagged for review."
)

plain_language <- function(findings) {
  if (!nrow(findings)) return(findings)
  findings %>% mutate(
    friendly = ifelse(rule %in% names(.PLAIN), unname(.PLAIN[rule]), message))
}

# one supportive "Agent Insight" line for the most serious finding
agent_insight <- function(findings, mapping = NULL) {
  intro <- if (!is.null(mapping) && nrow(mapping))
    paste0("I lined your file up to the SPC standard (",
           nrow(mapping), " columns matched). ") else ""
  if (!nrow(findings))
    return(paste0(intro, "Everything checks out — you're ready to submit. \U0001F389"))
  pl <- plain_language(findings)
  worst <- pl %>% arrange(factor(severity, c("error", "warning"))) %>% slice(1)
  paste0(intro, "I did spot something: ", worst$friendly,
         if (!is.na(worst$record_id)) paste0(" (record ", worst$record_id, ")") else "")
}

# ---- LLM availability (optional enhancement) --------------------------------
# Returns TRUE only if a local model endpoint is reachable. In the offline
# appliance with no model loaded this is FALSE and the deterministic path is
# used. Wire to ellmer::chat_ollama() / chattr when a model is provisioned.
llm_available <- function(host = Sys.getenv("OLLAMA_HOST", "http://localhost:11434")) {
  ok <- tryCatch({
    con <- url(file.path(host, "api/tags")); on.exit(close(con), add = TRUE)
    length(readLines(con, n = 1, warn = FALSE)) > 0
  }, error = function(e) FALSE)
  isTRUE(ok)
}
