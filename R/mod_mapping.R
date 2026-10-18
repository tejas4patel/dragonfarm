mod_mapping_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::card(
      bslib::card_header("Drag columns into the slots"),
      shiny::radioButtons(
        ns("mode"), NULL, inline = TRUE,
        choices = c("Fine-tune: prompt and response" = "messages",
                    "Preference pairs: prompt, chosen, rejected" = "pairs",
                    "Reinforcement learning: prompt and optional reference" = "prompts")
      ),
      shiny::uiOutput(ns("mode_help")),
      shiny::uiOutput(ns("buckets"))
    ),
    bslib::layout_columns(
      col_widths = c(6, 6),
      bslib::card(
        bslib::card_header("Templates"),
        shiny::p(class = "text-muted small", "Filled in from the slots. Use {column} and \\n for a line break."),
        shiny::textInput(ns("system_tpl"), "System (optional)", value = "", width = "100%",
                         placeholder = "You are a support agent for a smart-home company."),
        shiny::textInput(ns("prompt_tpl"), "Prompt", value = "", width = "100%"),
        shiny::conditionalPanel(
          condition = sprintf("input['%s'] == 'messages'", ns("mode")),
          shiny::textInput(ns("response_tpl"), "Response", value = "", width = "100%")
        ),
        shiny::conditionalPanel(
          condition = sprintf("input['%s'] == 'pairs'", ns("mode")),
          shiny::textInput(ns("chosen_tpl"), "Chosen (the better reply)", value = "", width = "100%"),
          shiny::textInput(ns("rejected_tpl"), "Rejected (the worse reply)", value = "", width = "100%")
        ),
        shiny::conditionalPanel(
          condition = sprintf("input['%s'] == 'prompts'", ns("mode")),
          shiny::textInput(ns("reference_tpl"), "Reference answer (optional, for exact and numeric rewards)", value = "", width = "100%")
        ),
        shiny::uiOutput(ns("status"))
      ),
      bslib::card(
        bslib::card_header("How the model will see it"),
        shiny::uiOutput(ns("preview"))
      )
    ),
    bslib::card(
      bslib::card_header("Let a stronger model write the replies"),
      shiny::p(class = "hint", "Thin or uneven replies? A bigger model answers your prompts instead, and you train the small one on its answers. Review them before training."),
      bslib::layout_columns(col_widths = c(4, 4, 2, 2),
        shiny::selectInput(ns("teacher_kind"), "Teacher", choices = c("A model on this machine" = "local", "Claude API" = "anthropic",
                                                                     "OpenRouter (free tier)" = "openrouter", "Groq (free tier)" = "groq")),
        shiny::textInput(ns("teacher_model"), "Model", value = "", placeholder = "Qwen/Qwen2.5-7B-Instruct", width = "100%"),
        shiny::numericInput(ns("teacher_n"), "Prompts", value = 50, min = 1, max = 2000, step = 10),
        shiny::div(class = "btn-row", shiny::actionButton(ns("teach"), "Write replies", class = "btn-outline-primary"))
      ),
      shiny::uiOutput(ns("teach_status"))
    )
  )
}

chips_to_template <- function(chips) {
  chips <- chips[nzchar(chips)]
  if (!length(chips)) return("")
  paste0("{", chips, "}", collapse = "\\n\\n")
}

mod_mapping_server <- function(id, state, nav_to) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns
    mode <- shiny::reactive(input$mode %||% "messages")

    # D-16: a teacher writes the replies in the background; the result loads
    # here as a new prompt-and-response set.
    teach_job <- shiny::reactiveVal(NULL)
    teach_state <- shiny::reactiveVal(NULL)
    shiny::observeEvent(input$teach, {
      m <- state$mapped
      if (is.null(m)) return(shiny::showNotification("Map the prompt column first.", type = "warning"))
      prompts <- tryCatch(utils::head(unique(as_prompt_vector(m)), input$teacher_n %||% 50), error = function(e) character())
      if (!length(prompts)) return(shiny::showNotification("No prompts to answer.", type = "warning"))
      kind <- input$teacher_kind %||% "local"
      model <- trimws(input$teacher_model %||% "")
      teacher <- switch(kind,
        local = list(kind = "local", model = if (nzchar(model)) model else state$hardware$tier$model %||% "Qwen/Qwen2.5-7B-Instruct"),
        anthropic = list(kind = "anthropic", model = if (nzchar(model)) model else "claude-sonnet-5"),
        list(kind = "provider", provider = kind, model = model))
      if (identical(teacher$kind, "anthropic") && !nzchar(Sys.getenv("ANTHROPIC_API_KEY"))) {
        return(shiny::showNotification("Add your Claude API key in Settings first.", type = "warning", duration = 10))
      }
      if (identical(teacher$kind, "provider")) {
        p <- provider_info(kind)
        if (!nzchar(model)) return(shiny::showNotification(sprintf("Name a %s model.", p$title), type = "warning"))
        if (!nzchar(Sys.getenv(p$key_env)) || !isTRUE(provider_status(kind)$opted_in)) {
          return(shiny::showNotification(sprintf("Add your %s key and turn it on under Free tiers in Settings first.", p$title), type = "warning", duration = 10))
        }
      }
      sys <- if (!is.null(m$mapping$system)) tryCatch(unique(render_template(m$mapping$system, m$data))[1], error = function(e) NULL)
      job <- tryCatch(synth_job_start(prompts, teacher, system = if (length(sys) && nzchar(sys)) sys), error = function(e) { notify_error(e); NULL })
      if (is.null(job)) return()
      teach_job(job); teach_state(list(state = "queued", n_prompts = length(prompts)))
    })
    shiny::observe({
      job <- teach_job()
      shiny::req(job)
      st <- synth_job_status(job$status)
      teach_state(st)
      if (st$state %in% c("queued", "running")) return(shiny::invalidateLater(2000))
      teach_job(NULL)
      if (identical(st$state, "succeeded")) {
        ds <- dragon_map(dragon_dataset(st$file, name = basename(st$file)), prompt = "prompt", response = "response")
        state$dataset <- ds
        state$mapped <- ds
        shiny::showNotification(sprintf("%d replies written by %s. Review them, then train.", st$n_kept, st$teacher), type = "message", duration = 8)
      }
    })
    output$teach_status <- shiny::renderUI({
      st <- teach_state()
      if (is.null(st)) return(NULL)
      msg <- switch(st$state,
        queued = , running = sprintf("Writing replies to %s prompts in the background.", st$n_prompts %||% "the"),
        succeeded = sprintf("Done: %s replies kept of %s prompts (%s dropped by quality checks).", st$n_kept, st$n_prompts, st$dropped %||% 0),
        failed = paste("Could not write the replies:", st$error %||% "no details"),
        "")
      shiny::p(class = paste("small", if (identical(st$state, "failed")) "text-warning"), msg)
    })

    output$mode_help <- shiny::renderUI({
      if (identical(mode(), "pairs")) {
        shiny::p(class = "text-muted small",
          "Each row needs one prompt and two replies to it: the one you prefer and the one you do not. ",
          "This feeds preference optimization (DPO or ORPO), usually on top of a fine-tuned run.")
      } else if (identical(mode(), "prompts")) {
        shiny::p(class = "text-muted small",
          "Each row is a prompt the model practises on. A reference answer lets exact and numeric rewards check it. ",
          "Other columns are available to custom reward functions. This feeds GRPO in the Train step.")
      } else {
        shiny::p(class = "text-muted small",
          "Drop one or more columns into Prompt and Response. Several columns in one slot are joined with a blank line. ",
          "System is optional. Edit the templates below for anything fancier.")
      }
    })

    output$buckets <- shiny::renderUI({
      ds <- state$dataset
      if (is.null(ds)) return(shiny::p(class = "hint", "Load a dataset first."))
      cols <- names(ds$data)
      # Pointer-event fallback instead of native HTML5 drag: works on touch
      # screens and with automated browsers. Set per list; bucket_list() does
      # not pass options down.
      drag_opts <- sortable::sortable_options(forceFallback = TRUE, fallbackTolerance = 3, animation = 120)
      slots <- list(
        sortable::add_rank_list("Columns", labels = cols, input_id = ns("cols"), options = drag_opts),
        sortable::add_rank_list("System", labels = NULL, input_id = ns("system"), options = drag_opts),
        sortable::add_rank_list("Prompt", labels = NULL, input_id = ns("prompt"), options = drag_opts)
      )
      slots <- switch(mode(),
        pairs = c(slots, list(
          sortable::add_rank_list("Chosen", labels = NULL, input_id = ns("chosen"), options = drag_opts),
          sortable::add_rank_list("Rejected", labels = NULL, input_id = ns("rejected"), options = drag_opts)
        )),
        prompts = c(slots, list(
          sortable::add_rank_list("Reference (optional)", labels = NULL, input_id = ns("reference"), options = drag_opts)
        )),
        c(slots, list(
          sortable::add_rank_list("Response", labels = NULL, input_id = ns("response"), options = drag_opts)
        ))
      )
      do.call(sortable::bucket_list, c(
        list(header = NULL, group_name = ns("buckets"), orientation = "horizontal",
             class = "default-sortable dragon-buckets"),
        slots
      ))
    })

    # Chips dropped into a slot rewrite that slot's template.
    bind_slot <- function(slot, field) {
      shiny::observeEvent(input[[slot]], {
        shiny::updateTextInput(session, field, value = chips_to_template(input[[slot]]))
      }, ignoreNULL = FALSE, ignoreInit = TRUE)
    }
    bind_slot("prompt", "prompt_tpl")
    bind_slot("response", "response_tpl")
    bind_slot("chosen", "chosen_tpl")
    bind_slot("rejected", "rejected_tpl")
    bind_slot("reference", "reference_tpl")
    shiny::observeEvent(input$system, {
      if (length(input$system)) shiny::updateTextInput(session, "system_tpl", value = chips_to_template(input$system))
    }, ignoreNULL = FALSE, ignoreInit = TRUE)

    shiny::observeEvent(state$dataset, {
      for (f in c("prompt_tpl", "response_tpl", "chosen_tpl", "rejected_tpl", "reference_tpl", "system_tpl")) {
        shiny::updateTextInput(session, f, value = "")
      }
    })

    mapped <- shiny::reactive({
      ds <- state$dataset
      if (is.null(ds)) return(NULL)
      p <- unescape_newlines(input$prompt_tpl %||% "")
      s <- unescape_newlines(input$system_tpl %||% "")
      sys <- if (nzchar(trimws(s))) s
      # A dataset that arrives already mapped (the Documents tab's reviewed questions)
      # stays mapped until a template is typed here; otherwise this module would
      # clear state$mapped the moment the dataset changed.
      if (!nzchar(trimws(p))) return(if (!is.null(ds$mapping)) ds else NULL)
      if (identical(mode(), "prompts")) {
        ref <- unescape_newlines(input$reference_tpl %||% "")
        return(tryCatch(
          dragon_map_prompts(ds, prompt = p, reference = if (nzchar(trimws(ref))) ref, system = sys),
          error = function(e) structure(list(message = conditionMessage(e)), class = "mapping_error")
        ))
      }
      if (identical(mode(), "pairs")) {
        ch <- unescape_newlines(input$chosen_tpl %||% "")
        rj <- unescape_newlines(input$rejected_tpl %||% "")
        if (!nzchar(trimws(ch)) || !nzchar(trimws(rj))) return(NULL)
        return(tryCatch(
          dragon_map_pairs(ds, prompt = p, chosen = ch, rejected = rj, system = sys),
          error = function(e) structure(list(message = conditionMessage(e)), class = "mapping_error")
        ))
      }
      r <- unescape_newlines(input$response_tpl %||% "")
      if (!nzchar(trimws(r))) return(NULL)
      tryCatch(
        dragon_map(ds, prompt = p, response = r, system = sys),
        error = function(e) structure(list(message = conditionMessage(e)), class = "mapping_error")
      )
    })

    shiny::observe({
      m <- mapped()
      state$mapped <- if (inherits(m, "dragon_dataset")) m else NULL
    })

    output$status <- shiny::renderUI({
      m <- mapped()
      need <- switch(mode(), pairs = "Fill Prompt, Chosen, and Rejected to continue.", prompts = "Fill Prompt to continue.", "Fill Prompt and Response to continue.")
      if (is.null(m)) return(shiny::p(class = "hint", need))
      if (inherits(m, "mapping_error")) return(shiny::p(class = "text-danger small", m$message))
      shiny::tagList(
        shiny::p(class = "text-success small",
                 switch(mode(), pairs = "Preference mapping is valid.", prompts = "RL prompt mapping is valid.", "Mapping is valid.")),
        shiny::actionButton(ns("next"), "Next: choose a model", class = "btn-primary")
      )
    })
    shiny::observeEvent(input$`next`, nav_to("model"))

    output$preview <- shiny::renderUI({
      m <- mapped()
      if (!inherits(m, "dragon_dataset")) return(shiny::p(class = "hint", "The first three rows appear here as chat turns."))
      chat_preview_ui(preview_rows(m, seq_len(min(3, nrow(m$data)))))
    })
  })
}
