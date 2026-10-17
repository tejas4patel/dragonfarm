mod_pipeline_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_columns(
      col_widths = c(5, 7),
      bslib::card(
        bslib::card_header("Run a recipe"),
        shiny::p(class = "hint", "The standard loop, end to end: fine-tune on the mapped dataset, sample the result and let a judge rank it into preference pairs, run DPO on those pairs, then judge the DPO run against the fine-tuned one. Runs in a separate R process; watch it here."),
        bslib::layout_columns(
          col_widths = c(6, 6),
          shiny::selectInput(ns("judge_kind"), "Judge", choices = c("Claude API (ANTHROPIC_API_KEY)" = "anthropic", "Local model" = "local")),
          shiny::uiOutput(ns("judge_model_ui"))
        ),
        bslib::layout_columns(
          col_widths = c(6, 6),
          shiny::numericInput(ns("pair_prompts"), "Prompts to sample for pairs", value = 60, min = 4, step = 10),
          shiny::numericInput(ns("judge_n"), "Prompts to judge at the end", value = 12, min = 2, step = 2)
        ),
        shiny::uiOutput(ns("recipe_check")),
        shiny::actionButton(ns("start"), "Run recipe in the background", class = "btn-primary"),
        shiny::uiOutput(ns("launched"))
      ),
      bslib::card(
        bslib::card_header("Pipelines"),
        shiny::uiOutput(ns("pipelines"))
      )
    ),
    bslib::card(
      bslib::card_header("Lineage"),
      shiny::p(class = "hint", "Every run in this directory, with what it started from and what it measured. Chained stages appear under their parents."),
      shiny::div(class = "table-wrap", shiny::tableOutput(ns("lineage")))
    )
  )
}

mod_pipeline_server <- function(id, state, runs_dir) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    output$judge_model_ui <- shiny::renderUI({
      if (identical(input$judge_kind, "local")) {
        shiny::textInput(ns("judge_model"), "Model id or directory", value = "Qwen/Qwen2.5-1.5B-Instruct")
      } else {
        shiny::selectInput(ns("judge_model"), "Model", choices = c("claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5"))
      }
    })

    problems <- shiny::reactive({
      out <- character()
      m <- state$mapped
      if (is.null(m)) out <- c(out, "Map a prompt/response dataset first (steps 1 and 2).")
      else if (!identical(mapping_kind(m), "messages")) out <- c(out, "The recipe starts with fine-tuning, so the dataset must be mapped as prompt and response.")
      if (is.null(state$model$id) || !nzchar(state$model$id)) out <- c(out, "Choose a model (step 3).")
      if (identical(input$judge_kind, "anthropic") && !nzchar(Sys.getenv("ANTHROPIC_API_KEY"))) out <- c(out, "ANTHROPIC_API_KEY is not set in this R session; set it or pick a local judge.")
      out
    })
    # The recipe's steps, built once for both the plan and the start button.
    recipe_steps <- shiny::reactive({
      if (length(problems())) return(NULL)
      judge <- if (identical(input$judge_kind, "local")) trimws(input$judge_model %||% "") else dragon_judge_anthropic(model = input$judge_model %||% "claude-sonnet-5")
      list(
        dragon_step_train(state$mapped),
        dragon_step_synthesize_pairs(prompts = "train", n = input$pair_prompts %||% 60, judge = judge),
        dragon_step_prefer(method = "dpo"),
        dragon_step_judge(against = "base", judge = judge, n = input$judge_n %||% 12),
        dragon_step_evaluate(metrics = c("token_f1", "length_ratio"))
      )
    })
    plan <- shiny::reactive({
      steps <- recipe_steps()
      if (is.null(steps)) return(NULL)
      tryCatch(pipeline_plan(state$model$id, steps, runs_dir), error = function(e) NULL)
    })

    # The plan: each step, the GPU, anything that leaves the machine, and how
    # long it took here before. Starting the recipe is the approval.
    output$recipe_check <- shiny::renderUI({
      p <- problems()
      if (length(p)) return(shiny::tags$ul(class = "checklist bad", lapply(p, shiny::tags$li)))
      pl <- plan()
      if (is.null(pl)) return(NULL)
      shiny::div(class = "plan-view", shiny::tags$h6("The plan"), plan_ui(pl))
    })

    launched <- shiny::reactiveVal(NULL)
    shiny::observeEvent(input$start, {
      p <- problems()
      if (length(p)) {
        shiny::showNotification(paste(p, collapse = " "), type = "warning")
        return()
      }
      steps <- recipe_steps()
      pl <- plan()
      res <- tryCatch(
        suppressMessages(dragon_pipeline(state$model$id, steps, runs_dir = runs_dir, name = "recipe", background = TRUE)),
        error = function(e) { notify_error(e); NULL }
      )
      if (!is.null(res)) {
        if (!is.null(pl)) plan_record_approval(paste("pipeline", res$id), pl, runs_dir)
        launched(res)
        shiny::showNotification(sprintf("Pipeline %s started.", res$id), type = "message")
      }
    })
    output$launched <- shiny::renderUI({
      l <- launched()
      if (is.null(l)) return(NULL)
      shiny::p(class = "small text-muted", "Started ", shiny::code(l$id), ". Log: ", shiny::code(l$log))
    })

    records <- shiny::reactivePoll(3000, session,
      checkFunc = function() {
        d <- file.path(runs_dir, "pipelines")
        f <- list.files(d, pattern = "\\.json$", full.names = TRUE)
        paste(f, file.info(f)$mtime, collapse = "|")
      },
      valueFunc = function() {
        d <- file.path(runs_dir, "pipelines")
        f <- sort(list.files(d, pattern = "\\.json$", full.names = TRUE), decreasing = TRUE)
        lapply(f, function(p) tryCatch(read_json_retry(p), error = function(e) NULL))
      }
    )

    output$pipelines <- shiny::renderUI({
      recs <- Filter(Negate(is.null), records())
      if (!length(recs)) return(shiny::p(class = "hint", "No pipelines yet."))
      shiny::tagList(lapply(recs[seq_len(min(5, length(recs)))], function(r) {
        shiny::div(class = "pipeline",
          shiny::div(class = "pipeline-head", shiny::code(r$id), state_pill(r$status),
            if (isTRUE(r$status %in% c("queued", "running"))) shiny::tags$button(
              type = "button", class = "btn btn-sm btn-outline-danger fb-btn", title = "Stop after the current step",
              onclick = sprintf("Shiny.setInputValue('%s', {id: '%s', nonce: Math.random()}, {priority: 'event'})", ns("cancel"), r$id),
              "Cancel")),
          shiny::tags$ol(class = "pipeline-steps", lapply(r$steps, function(s) {
            detail <- if (!is.null(s$run)) shiny::code(s$run)
                      else if (!is.null(s$summary$pairs)) sprintf("%d pairs", s$summary$pairs)
                      else if (!is.null(s$summary$win_rate)) sprintf("wins %.0f%%", 100 * s$summary$win_rate)
                      else if (!is.null(s$summary$mean_score)) sprintf("score %.1f", s$summary$mean_score)
                      else NULL
            shiny::tags$li(shiny::span(class = paste("step", s$state), s$type), " ", detail,
                           if (!is.null(s$error)) shiny::div(class = "text-danger small", s$error))
          }))
        )
      }))
    })

    shiny::observeEvent(input$cancel, {
      id <- input$cancel$id
      if (is.null(id) || !nzchar(id)) return()
      res <- tryCatch(suppressMessages(dragon_pipeline_cancel(id, runs_dir = runs_dir, wait = FALSE)),
                      error = function(e) { notify_error(e); NULL })
      if (!is.null(res)) {
        shiny::showNotification("Cancel requested. A training step stops after saving a checkpoint; any other step finishes first, then the pipeline stops.",
                                type = "message", duration = 8)
      }
    })

    runs <- shiny::reactivePoll(3000, session,
      checkFunc = function() runs_change_signature(runs_dir),
      valueFunc = function() tryCatch(dragon_compare(runs_dir = runs_dir), error = function(e) NULL)
    )

    output$lineage <- shiny::renderTable({
      cmp <- runs()
      if (is.null(cmp) || !nrow(cmp)) return(data.frame(note = "No runs yet."))
      df <- as.data.frame(cmp)
      ordered <- lineage_order(df$id, df$from)
      df <- df[match(ordered$id, df$id), , drop = FALSE]
      df$run <- paste0(strrep("\u2007\u2007", ordered$depth), ifelse(ordered$depth > 0, "\u21b3 ", ""), df$id)
      df$model <- basename(df$model)
      df$method <- ifelse(is.na(df$method), "", df$method)
      df$id <- NULL
      df$from <- NULL
      keep <- vapply(df, function(col) is.character(col) || any(!is.na(col)), logical(1))
      df[, c("run", setdiff(names(df)[keep], "run")), drop = FALSE]
    }, spacing = "xs", width = "100%", na = "", digits = 3)
  })
}

# Depth-first order of runs by parent, roots first (newest root first).
lineage_order <- function(ids, parents) {
  parents[!parents %in% ids] <- NA
  out_id <- character()
  out_depth <- integer()
  visit <- function(id, depth) {
    out_id <<- c(out_id, id)
    out_depth <<- c(out_depth, depth)
    for (child in ids[!is.na(parents) & parents == id]) visit(child, depth + 1L)
  }
  for (root in ids[is.na(parents)]) visit(root, 0L)
  # anything left (cycles or orphans) goes at the end
  for (rest in setdiff(ids, out_id)) visit(rest, 0L)
  list(id = out_id, depth = out_depth)
}
