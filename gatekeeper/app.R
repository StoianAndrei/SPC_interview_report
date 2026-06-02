# =============================================================================
# app.R  --  Intelligent Pre-Ingestion Gateway for TUFMAN 2  (Shiny dashboard)
# -----------------------------------------------------------------------------
# Upload -> instant 3-tier validation -> health score + spatial CPUE map +
# flags workspace (fix & re-validate) -> conditional forward to TUFMAN 2.
# Run:  shiny::runApp("gatekeeper")
# =============================================================================
suppressPackageStartupMessages({
  library(shiny)
  library(DT)
  library(leaflet)
  library(plotly)
})
source("global.R")

# ---- UI ---------------------------------------------------------------------
ui <- fluidPage(
  tags$head(tags$style(HTML("
    .gk-banner{padding:14px;border-radius:8px;color:#fff;font-weight:600;margin:8px 0}
    .gk-ok{background:#2A9D8F}.gk-err{background:#E4572E}.gk-warn{background:#F2C14E;color:#222}
    .gk-card{background:#0B3C5D;color:#fff;padding:12px;border-radius:8px;text-align:center}
    .gk-card .v{font-size:26px;font-weight:700}
    body{background:#f6f8fa}"))),
  titlePanel("🛡️  Intelligent Pre-Ingestion Gateway for TUFMAN 2"),
  p("Validate a country's catch/effort, size, observer or E-Monitoring submission ",
    "before it reaches TUFMAN 2 — schema, sanity and compliance checks, with an ",
    "instant dashboard and a fix-and-resubmit loop."),
  sidebarLayout(
    sidebarPanel(
      width = 3,
      selectInput("country", "Member (multi-tenant scope)", COUNTRY_CHOICES),
      selectInput("category", "Data category", CATEGORY_LABELS),
      radioButtons("source", "Input", c("Use bundled sample" = "sample",
                                         "Upload CSV" = "csv")),
      conditionalPanel("input.source == 'csv'",
        fileInput("file", "CSV file", accept = ".csv"),
        helpText("Non-standard headers are auto-mapped to the standard schema.")),
      actionButton("validate", "Validate submission", class = "btn-primary"),
      hr(),
      helpText("Longline E-Monitoring JSON has its own tab (schema + speed checks)."),
      tags$small(textOutput("ref_note"))
    ),
    mainPanel(
      width = 9,
      uiOutput("banner"),
      tabsetPanel(
        id = "tabs",
        tabPanel("Overview",
          fluidRow(
            column(3, div(class = "gk-card", div(class = "v", textOutput("c_rows")), "records")),
            column(3, div(class = "gk-card", div(class = "v", textOutput("c_err")), "blocking errors")),
            column(3, div(class = "gk-card", div(class = "v", textOutput("c_warn")), "warnings")),
            column(3, div(class = "gk-card", div(class = "v", textOutput("c_health")), "health score"))),
          br(),
          fluidRow(column(6, plotlyOutput("gauge", height = 260)),
                   column(6, h4("What this means"), uiOutput("health_msgs"),
                          tableOutput("health_breakdown"))),
          h4("Auto-mapping report"), tableOutput("mapping")),
        tabPanel("Spatial CPUE map", leafletOutput("map", height = 560)),
        tabPanel("Flags workspace",
          p("Edit a flagged cell inline, then re-validate. Clean records stay; ",
            "blocking errors hold the whole submission."),
          actionButton("revalidate", "Re-validate after edits", class = "btn-primary"),
          downloadButton("download", "Download corrected CSV"),
          br(), br(), DTOutput("findings"),
          h4("Submission data (editable)"), DTOutput("editable")),
        tabPanel("Forward to TUFMAN 2",
          p("Two-step: obtain a country-scoped token, then conditionally POST. ",
            "Only a submission with zero blocking errors is forwarded."),
          actionButton("forward", "Obtain token & forward", class = "btn-primary"),
          br(), br(), uiOutput("forward_result"),
          h4("Submission envelope (preview)"), verbatimTextOutput("envelope")),
        tabPanel("Longline E-Monitoring JSON",
          p("The TUFMAN 2 LL JSON contract: ISO 6709 coordinates, FAO species ",
            "codes, the activity_id=1 conditional, and the catch anyOf rule."),
          radioButtons("json_src", NULL,
            c("Clean sample" = "tufman2_ll_sample.json",
              "Dirty sample (planted errors)" = "tufman2_ll_dirty.json"), inline = TRUE),
          actionButton("validate_json", "Validate JSON", class = "btn-primary"),
          br(), br(),
          fluidRow(column(6, h4("Raw payload"), verbatimTextOutput("json_raw")),
                   column(6, h4("Schema findings"), DTOutput("json_findings"))))
      )
    )
  )
)

# ---- server -----------------------------------------------------------------
server <- function(input, output, session) {
  output$ref_note <- renderText(sprintf(
    "Reference: %d vessels, %d species, %d thresholds.",
    nrow(REF$registry), nrow(REF$species), length(REF$thresholds)))

  rv <- reactiveValues(data = NULL, findings = NULL, status = NULL,
                       mapping = NULL, health = NULL, category = NULL)

  load_data <- function() {
    cat <- input$category
    if (input$source == "sample") {
      df <- GK_SAMPLES[[cat]]
      mapping <- NULL
    } else {
      req(input$file)
      raw <- readr::read_csv(input$file$datapath, show_col_types = FALSE)
      mp <- automap_columns(raw, cat)
      df <- mp$data; mapping <- mp$mapping
    }
    # multi-tenant: scope to the selected member where a flag column exists
    if ("flag" %in% names(df)) df <- dplyr::filter(df, flag == input$country | is.na(flag))
    list(df = df, mapping = mapping, cat = cat)
  }

  run_validation <- function() {
    ld <- load_data()
    df <- ld$df; cat <- ld$cat
    findings <- validate_submission(df, cat, REF, gk_context())
    status <- submission_status(findings, nrow(df))
    rv$data <- df; rv$findings <- findings; rv$status <- status
    rv$mapping <- ld$mapping; rv$category <- cat
    rv$health <- health_score(df, cat, findings)
  }

  observeEvent(input$validate, run_validation())
  observeEvent(input$revalidate, {
    req(rv$data)
    findings <- validate_submission(rv$data, rv$category, REF, gk_context())
    rv$findings <- findings
    rv$status <- submission_status(findings, nrow(rv$data))
    rv$health <- health_score(rv$data, rv$category, findings)
  })

  output$banner <- renderUI({
    s <- rv$status; if (is.null(s)) return(helpText("Click ‘Validate submission’ to begin."))
    if (s$can_forward)
      div(class = "gk-banner gk-ok",
          sprintf("✓ READY — %d records, no blocking errors. %d warning(s) to review.",
                  s$n_rows, s$n_warning))
    else
      div(class = "gk-banner gk-err",
          sprintf("✗ HELD — %d blocking error(s) across %d record(s). Fix before submission.",
                  s$n_error, s$flagged_rows))
  })

  output$c_rows   <- renderText(if (is.null(rv$status)) "—" else rv$status$n_rows)
  output$c_err    <- renderText(if (is.null(rv$status)) "—" else rv$status$n_error)
  output$c_warn   <- renderText(if (is.null(rv$status)) "—" else rv$status$n_warning)
  output$c_health <- renderText(if (is.null(rv$health)) "—" else rv$health$score)

  output$gauge <- renderPlotly({
    req(rv$health)
    plot_ly(type = "indicator", mode = "gauge+number", value = rv$health$score,
            title = list(text = paste0("Health: ", as.character(rv$health$grade))),
            gauge = list(axis = list(range = c(0, 100)),
                         bar = list(color = "#1D6E8C"),
                         steps = list(
                           list(range = c(0, 50), color = "#E4572E"),
                           list(range = c(50, 75), color = "#F2C14E"),
                           list(range = c(75, 100), color = "#2A9D8F")))) %>%
      layout(margin = list(t = 40, b = 10))
  })
  output$health_msgs <- renderUI({
    req(rv$health); tags$ul(lapply(rv$health$messages, tags$li))
  })
  output$health_breakdown <- renderTable(rv$health$breakdown)

  output$mapping <- renderTable({
    if (is.null(rv$mapping)) data.frame(note = "Bundled sample — already standardised.")
    else rv$mapping
  })

  output$map <- renderLeaflet({
    req(rv$data)
    if (!all(c("latitude", "longitude") %in% names(rv$data)))
      return(leaflet() %>% addTiles() %>% setView(170, -5, 3))
    pts <- compute_cpue(rv$data, rv$findings)
    pal <- colorNumeric("viridis", pts$cpue, na.color = "#999")
    leaflet(pts) %>% addProviderTiles("CartoDB.Positron") %>%
      setView(180, -5, 3) %>%
      addCircleMarkers(~lon, ~lat,
        radius = ~ifelse(flagged, 8, 5),
        color = ~ifelse(flagged, "#E4572E", pal(cpue)),
        stroke = ~flagged, weight = 2, fillOpacity = 0.8,
        popup = ~paste0("Trip: ", trip_id, "<br>CPUE: ", round(cpue, 2),
                        ifelse(flagged, "<br><b>FLAGGED</b>", ""))) %>%
      addLegend("bottomright", pal = pal, values = ~cpue, title = "CPUE")
  })

  output$findings <- renderDT({
    req(rv$findings)
    datatable(rv$findings, filter = "top", options = list(pageLength = 10),
              rownames = FALSE) %>%
      formatStyle("severity", target = "row",
        backgroundColor = styleEqual(c("error", "warning"),
                                     c("#fde2dc", "#fcf3d6")))
  })
  output$editable <- renderDT({
    req(rv$data)
    datatable(rv$data, editable = TRUE, options = list(pageLength = 8),
              rownames = FALSE)
  })
  observeEvent(input$editable_cell_edit, {
    info <- input$editable_cell_edit
    df <- rv$data
    df[info$row, info$col + 1] <- info$value
    rv$data <- df
  })

  output$download <- downloadHandler(
    filename = function() paste0(rv$category, "_corrected.csv"),
    content = function(file) readr::write_csv(rv$data, file))

  # ---- forward to TUFMAN 2 ----
  envelope_r <- reactive({
    req(rv$data, rv$status)
    trip <- rv$data[1, , drop = FALSE]
    build_tufman2_envelope(trip, rv$status, input$country)
  })
  output$envelope <- renderText(jsonlite::toJSON(envelope_r(), auto_unbox = TRUE,
                                                 pretty = TRUE))
  observeEvent(input$forward, {
    req(rv$status)
    tok <- tufman2_token(input$country)
    res <- forward_to_tufman2(rv$status, envelope_r(), tok)
    output$forward_result <- renderUI({
      cls <- if (isTRUE(res$forwarded)) "gk-banner gk-ok" else "gk-banner gk-err"
      div(class = cls, res$message,
          br(), tags$small(paste("token scope:", tok$scope)))
    })
  })

  # ---- LL JSON tab ----
  observeEvent(input$validate_json, {
    path <- file.path(GK_PATHS$samples, input$json_src)
    res <- ingest_tufman2_ll(path, REF$registry)
    output$json_raw <- renderText(paste(readLines(path), collapse = "\n"))
    output$json_findings <- renderDT(
      datatable(if (nrow(res$schema_findings)) res$schema_findings
                else data.frame(result = "✓ Schema valid — payload accepted."),
                options = list(pageLength = 10), rownames = FALSE))
  })
}

shinyApp(ui, server)
