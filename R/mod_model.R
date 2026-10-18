mod_model_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::layout_columns(
    col_widths = c(7, 5),
    bslib::card(
      bslib::card_header(label_with_info("Pick a base model", "train")),
      shiny::uiOutput(ns("preset_cards")),
      shiny::hr(),
      shiny::textInput(ns("custom"), "Or any Hugging Face model id", placeholder = "org/model-name", width = "100%"),
      shiny::checkboxInput(ns("trust"), "Allow custom code from the model repository (trust_remote_code)", value = FALSE)
    ),
    bslib::card(
      bslib::card_header("This machine"),
      shiny::actionButton(ns("detect"), "Detect hardware", class = "btn-outline-primary"),
      shiny::uiOutput(ns("hardware")),
      shiny::hr(),
      shiny::uiOutput(ns("verdict"))
    )
  )
}

mod_model_server <- function(id, state, nav_to) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns
    presets <- dragon_presets()

    # One selectable card per preset: name, size, memory, licence, and the note.
    output$preset_cards <- shiny::renderUI({
      cards <- lapply(seq_len(nrow(presets)), function(i) {
        p <- presets[i, ]
        org <- sub("/.*$", "", p$id)
        shiny::tags$span(class = "df-model",
          shiny::tags$span(class = "df-model-head",
            shiny::tags$span(class = "df-model-name", sub("^.*/", "", p$id)),
            shiny::tags$span(class = "df-chip size", p$params),
            shiny::tags$span(class = "df-chip stage", dragon_stage(model_size_b(p$id)))
          ),
          shiny::tags$span(class = "df-model-org", org),
          shiny::tags$span(class = "df-model-note", p$notes),
          shiny::tags$span(class = "df-model-meta",
            shiny::tags$span(class = "df-chip", sprintf("%s GB+", p$min_vram_gb)),
            shiny::tags$span(class = "df-chip", p$license),
            if (isTRUE(p$gated)) shiny::tags$span(class = "df-chip warn", "token")
          )
        )
      })
      shiny::radioButtons(ns("preset"), NULL, choiceNames = cards, choiceValues = presets$id,
                          selected = "Qwen/Qwen2.5-0.5B-Instruct", width = "100%")
    })

    chosen <- shiny::reactive({
      custom <- trimws(input$custom %||% "")
      if (nzchar(custom)) custom else input$preset
    })
    shiny::observe({
      state$model <- list(id = chosen(), trust_remote_code = isTRUE(input$trust))
    })

    # On the documents route, start from the model the hardware check
    # recommends (7B in 4-bit at 8 GB, 3B at 6 GB, 1.5B below), unless a
    # different preset or a custom id has already been chosen.
    shiny::observeEvent(list(state$hardware, state$route), {
      pick <- recommended_preset(state$hardware, state$route)
      untouched <- identical(input$preset, "Qwen/Qwen2.5-0.5B-Instruct") && !nzchar(trimws(input$custom %||% ""))
      if (!is.null(pick) && untouched) shiny::updateRadioButtons(session, "preset", selected = pick)
    }, ignoreNULL = FALSE)

    shiny::observeEvent(input$detect, {
      shiny::withProgress(message = "Checking Python and hardware. First time builds the environment.", {
        hw <- tryCatch(hardware_info(), error = function(e) { notify_error(e); NULL })
        state$hardware <- hw
        if (is.null(hw)) shiny::showNotification("Hardware check failed. See the R console.", type = "error")
      })
    })

    output$hardware <- shiny::renderUI({
      hw <- state$hardware
      if (is.null(hw)) return(shiny::p(class = "hint", "Not checked yet. This also prepares the Python environment, which takes a few minutes the first time."))
      shiny::tagList(
        shiny::div(class = "kv", shiny::span("Device"), shiny::strong(hw$device_name)),
        if (identical(hw$device, "cuda")) shiny::div(class = "kv", shiny::span("GPU memory"), shiny::strong(sprintf("%.1f GB", hw$vram_gb))),
        shiny::div(class = "kv", shiny::span("torch"), shiny::strong(hw$torch)),
        shiny::div(class = "kv", shiny::span("transformers"), shiny::strong(hw$transformers)),
        if (!is.null(hw$tier)) shiny::div(class = "kv", shiny::span("Default for answering"),
          shiny::strong(paste0(hw$tier$model, if (isTRUE(hw$tier$load_in_4bit)) " (4-bit)" else "")))
      )
    })

    output$verdict <- shiny::renderUI({
      id <- chosen()
      shiny::req(id)
      p <- preset_for(id)
      hw <- state$hardware
      notes <- list()
      if (!is.null(p) && p$gated && !hf_token_present()) {
        notes <- c(notes, list(shiny::p(class = "text-danger small",
          "This model is gated. Accept its license on huggingface.co and add your Hugging Face token in Settings before training.")))
      }
      size <- model_size_b(id)
      if (identical(state$route, "documents") && !is.na(size) && size < 3) {
        notes <- c(notes, list(shiny::p(class = "text-warning small",
          "For documents, models under 3B are wrong more often: untrained, the 0.5B on 14 of 55 test questions and the 1.5B on 6, against none for the 7B. Use a 3B or 7B, or keep this one for a fixed format such as JSON.")))
      }
      if (!is.null(hw) && !is.null(p)) {
        if (identical(hw$device, "cuda")) {
          if (hw$vram_gb < p$min_vram_gb) {
            notes <- c(notes, list(shiny::p(class = "text-warning small",
              sprintf("Needs about %d GB of GPU memory; this GPU has %.1f GB. Lower the batch size and sequence length, or turn on gradient checkpointing.", p$min_vram_gb, hw$vram_gb))))
          } else {
            notes <- c(notes, list(shiny::p(class = "text-success small", "Fits on this GPU.")))
          }
        } else if (identical(hw$device, "cpu") && p$min_vram_gb > 3) {
          notes <- c(notes, list(shiny::p(class = "text-warning small", "This model is slow to train on a CPU. Try the 135M or 360M models first.")))
        }
      }
      shiny::tagList(
        shiny::div(class = "kv", shiny::span("Selected"), shiny::code(id)),
        notes,
        shiny::actionButton(ns("next"), "Next: training settings", class = "btn-primary")
      )
    })
    shiny::observeEvent(input$`next`, nav_to("train"))
  })
}

# The preset to start from on the documents route: the model the hardware
# check recommends for answering, when it is one of the presets.
recommended_preset <- function(hw, route) {
  if (!identical(route, "documents") || is.null(hw) || is.null(hw$tier$model)) return(NULL)
  m <- hw$tier$model
  if (m %in% dragon_presets()$id) m else NULL
}
