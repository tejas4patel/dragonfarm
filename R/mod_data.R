mod_data_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::layout_columns(
    col_widths = c(4, 8),
    bslib::card(
      bslib::card_header("Dataset"),
      shiny::div(class = "dropzone",
        shiny::fileInput(ns("file"), label = NULL, buttonLabel = "Browse",
                         placeholder = "Drop a CSV, JSONL, JSON, or Parquet file here",
                         accept = c(".csv", ".tsv", ".jsonl", ".ndjson", ".json", ".parquet"), width = "100%")
      ),
      shiny::p(class = "text-muted small",
        "One row per training example. You will pick which columns form the prompt and the reply in the next step. Chat-format JSONL (a messages list per row) loads as whole conversations."),
      shiny::actionButton(ns("example"), "Load the example tickets", class = "btn-outline-primary"),
      shiny::uiOutput(ns("summary")),
      shiny::p(class = "hint mt-3", shiny::actionLink(ns("documents_route"), "Have documents instead of a table?"))
    ),
    bslib::card(
      bslib::card_header("Preview"),
      shiny::div(class = "table-wrap", shiny::tableOutput(ns("preview")))
    )
  )
}

mod_data_server <- function(id, state, nav_to) {
  shiny::moduleServer(id, function(input, output, session) {
    set_dataset <- function(ds) {
      state$dataset <- ds
      state$mapped <- NULL
      shiny::showNotification(sprintf("Loaded %d rows from %s.", nrow(ds$data), ds$name), type = "message", duration = 4)
    }

    shiny::observeEvent(input$file, {
      f <- input$file
      ext <- tolower(tools::file_ext(f$name))
      # Chat-format JSONL (rows of {"messages": [...]}, as Chat exports) is
      # already in training shape: load it as conversations, no mapping.
      if (ext %in% c("jsonl", "ndjson") && looks_like_conversations(f$datapath)) {
        ds <- tryCatch(dragon_conversations(f$datapath, name = f$name), error = function(e) { notify_error(e); NULL })
        if (is.null(ds)) return()
        state$dataset <- ds
        state$mapped <- ds
        return(shiny::showNotification(sprintf("Loaded %d conversations from %s. They are ready to train; no mapping needed.",
                                               nrow(ds$data), ds$name), type = "message", duration = 6))
      }
      ds <- tryCatch(
        dragon_dataset(f$datapath, format = ext, name = f$name),
        error = function(e) { notify_error(e); NULL }
      )
      if (!is.null(ds)) set_dataset(ds)
    })

    shiny::observeEvent(input$example, {
      set_dataset(dragon_dataset(dragon_example_data(), name = "support_tickets.jsonl (example)"))
    })
    shiny::observeEvent(input$documents_route, {
      state$route <- "documents"
      nav_to("documents")
    })

    output$summary <- shiny::renderUI({
      ds <- state$dataset
      if (is.null(ds)) return(shiny::p(class = "hint", "No dataset loaded yet."))
      types <- vapply(ds$data, function(col) class(col)[1], character(1))
      shiny::tagList(
        shiny::hr(),
        shiny::div(class = "kv", shiny::span("Name"), shiny::strong(ds$name)),
        shiny::div(class = "kv", shiny::span("Rows"), shiny::strong(format(nrow(ds$data), big.mark = ","))),
        shiny::div(class = "kv", shiny::span("Columns"), shiny::strong(ncol(ds$data))),
        shiny::tags$ul(class = "col-list", lapply(names(types), function(cn) {
          shiny::tags$li(shiny::code(cn), shiny::span(class = "type", types[[cn]]))
        })),
        shiny::actionButton(session$ns("next"), "Next: map columns", class = "btn-primary")
      )
    })

    shiny::observeEvent(input$`next`, nav_to("map"))

    output$preview <- shiny::renderTable({
      ds <- state$dataset
      shiny::req(ds)
      head_df <- utils::head(ds$data, 8)
      head_df <- head_df[, !vapply(head_df, is.list, TRUE), drop = FALSE]   # e.g. a conversation's messages
      head_df[] <- lapply(head_df, function(col) {
        col <- as.character(col)
        ifelse(nchar(col) > 120, paste0(substr(col, 1, 117), "..."), col)
      })
      head_df
    }, striped = TRUE, spacing = "xs", width = "100%")
  })
}
