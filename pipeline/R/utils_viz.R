# =============================================================================
# utils_viz.R  --  the "glass box": make every ingestion step visible
# -----------------------------------------------------------------------------
# The whole point of this project is a METHOD: at every step of the pipeline we
# emit (1) a data snapshot, (2) a small visual, and (3) a lineage record. By the
# end you can see exactly what each transformation did to the data -- no black
# boxes between the raw download and the final story.
#
# The pipeline keeps a running ledger in the `.LINEAGE` environment. Each stage
# calls `log_stage()` to append a row; `lineage_table()` / `lineage_plot()`
# render that ledger so the data's journey is itself a visualisation.
# =============================================================================

suppressPackageStartupMessages({
  library(kableExtra)
  library(scales)
})

.LINEAGE <- new.env(parent = emptyenv())
.LINEAGE$rows <- list()

#' Reset the lineage ledger (call once at the top of a run).
reset_lineage <- function() {
  .LINEAGE$rows <- list()
  invisible(TRUE)
}

#' Record one step in the data's journey.
#'
#' @param stage   short stage id, e.g. "ingest"
#' @param dataset which dataset this row describes
#' @param data    the data frame as it looks leaving this stage
#' @param note    one-line human description of what happened
#' @param status  "ok" | "warn" | "fix" | "fail"  (drives the colour)
log_stage <- function(stage, dataset, data, note = "", status = "ok") {
  n_na <- if (is.data.frame(data)) sum(is.na(data)) else NA_integer_
  row <- tibble(
    step     = length(.LINEAGE$rows) + 1L,
    stage    = stage,
    dataset  = dataset,
    rows     = if (is.data.frame(data)) nrow(data) else NA_integer_,
    cols     = if (is.data.frame(data)) ncol(data) else NA_integer_,
    n_missing = n_na,
    status   = status,
    note     = note
  )
  .LINEAGE$rows[[length(.LINEAGE$rows) + 1L]] <- row
  invisible(data)
}

#' The full lineage ledger as a tibble.
lineage_tbl <- function() {
  if (!length(.LINEAGE$rows)) return(tibble())
  bind_rows(.LINEAGE$rows)
}

#' A styled lineage table for the report.
lineage_table <- function() {
  lt <- lineage_tbl()
  if (!nrow(lt)) return(invisible(NULL))
  badge <- c(ok = "#2A9D8F", warn = "#F2C14E", fix = "#1D6E8C", fail = "#E4572E")
  lt %>%
    mutate(status = cell_spec(
      toupper(status), color = "white", background = badge[status],
      bold = TRUE, format = "html")) %>%
    kbl(escape = FALSE, format = "html",
        col.names = c("#", "Stage", "Dataset", "Rows", "Cols",
                      "Missing", "Status", "What happened")) %>%
    kable_styling(bootstrap_options = c("striped", "hover", "condensed"),
                  full_width = TRUE, position = "center")
}

#' A first-look preview of any table (head rows), styled.
preview_table <- function(data, n = 6, caption = NULL) {
  data %>%
    head(n) %>%
    kbl(caption = caption, format = "html") %>%
    kable_styling(bootstrap_options = c("striped", "hover", "condensed"),
                  full_width = TRUE, position = "center", font_size = 12)
}

#' The data-lineage visual: how each dataset's row count flows stage to stage.
#'
#' This is the signature picture of the "visualise ingestion at every step"
#' method -- the shape of the data as it moves down the pipeline. We follow the
#' real datasets through ingest -> validate -> clean, then the single harmonised
#' `panel` that the transform stage produces. (The intermediate join steps get
#' their own funnel in `join_funnel_plot()`.)
lineage_plot <- function() {
  lt <- lineage_tbl()
  if (!nrow(lt)) return(invisible(NULL))
  main <- lt %>% filter(stage == "ingest") %>% pull(dataset) %>% unique()
  keep <- c(main, "panel")
  d <- lt %>%
    filter(dataset %in% keep, stage %in% c("ingest", "validate", "clean", "transform")) %>%
    mutate(stage = factor(stage, levels = c("ingest", "validate", "clean", "transform")),
           dataset = factor(dataset, levels = keep))
  ggplot(d, aes(stage, rows, group = dataset, colour = dataset)) +
    geom_line(linewidth = 1, na.rm = TRUE) +
    geom_point(aes(shape = status), size = 3, na.rm = TRUE) +
    scale_y_continuous(labels = label_comma()) +
    scale_colour_manual(values = unname(unlist(SPC_COLOURS)), drop = FALSE) +
    labs(
      title = "Data lineage: row counts at every pipeline stage",
      subtitle = "Each line is one dataset; every point is a step where we paused to look",
      x = NULL, y = "Rows", colour = "Dataset", shape = "Status",
      caption = SPC_CAPTION
    ) +
    theme_spc() +
    theme(axis.text.x = element_text(angle = 20, hjust = 1))
}

#' The transform-stage join funnel: rows surviving each successive join.
join_funnel_plot <- function() {
  lt <- lineage_tbl()
  joins <- lt %>%
    filter(stage == "transform", dataset != "panel") %>%
    mutate(dataset = factor(dataset, levels = dataset))
  if (!nrow(joins)) return(invisible(NULL))
  ggplot(joins, aes(dataset, rows)) +
    geom_col(fill = SPC_COLOURS$ocean, width = 0.7) +
    geom_text(aes(label = label_comma()(rows)), vjust = -0.4,
              colour = SPC_COLOURS$deep, size = 3.4) +
    scale_y_continuous(labels = label_comma(),
                       expand = expansion(mult = c(0, 0.12))) +
    labs(title = "Join funnel: rows surviving each successive join",
         subtitle = "Inner/left joins onto the country–year grain — no rows lost here",
         x = NULL, y = "Rows", caption = SPC_CAPTION) +
    theme_spc()
}

#' Save a ggplot to output/figs and return it (so the Rmd can both show & keep).
keep_fig <- function(plot, name, w = 9, h = 5.2, dpi = 150) {
  path <- file.path(PATHS$figs, paste0(name, ".png"))
  ggsave(path, plot, width = w, height = h, dpi = dpi, bg = "white")
  invisible(plot)
}

#' Compact reporter for a value -> badge line (used in validation).
check_badge <- function(label, ok, detail = "") {
  colour <- if (ok) "#2A9D8F" else "#E4572E"
  mark   <- if (ok) "PASS" else "FAIL"
  glue('<span style="background:{colour};color:white;padding:2px 8px;',
       'border-radius:4px;font-weight:bold">{mark}</span> {label} ',
       '<span style="color:#8896A6">{detail}</span>')
}
