#!/usr/bin/env Rscript
# render.R -- build the glass-box pipeline report.
#
#   Rscript pipeline/render.R          # renders pipeline/fisheries_pipeline.html
#
# Runs from the repo root. For a quick, no-report smoke test of the pipeline
# itself use:  Rscript pipeline/R/pipeline.R
rmarkdown::render(
  input = "pipeline/fisheries_pipeline.Rmd",
  output_format = "html_document",
  knit_root_dir = normalizePath("pipeline")
)
