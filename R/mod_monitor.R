mod_monitor_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_columns(
      col_widths = c(4, 8),
      bslib::card(
        bslib::card_header("Runs"),
        shiny::checkboxInput(ns("show_archived"), "Show archived", value = FALSE),
        shiny::selectInput(ns("run"), NULL, choices = character(), width = "100%"),
        shiny::uiOutput(ns("facts")),
        shiny::conditionalPanel(
          condition = sprintf("!input['%s']", ns("show_archived")),
          # Cancel while a run is going, Resume once it stopped short; neither
          # for a finished run (both used to show for every run).
          shiny::uiOutput(ns("run_actions")),
          shiny::div(class = "cloud-actions", style = "margin-top: 8px;",
            shiny::actionButton(ns("archive"), "Archive", class = "btn-outline-secondary"),
            shiny::actionButton(ns("delete"), "Delete", class = "btn-outline-danger")
          )
        ),
        shiny::conditionalPanel(
          condition = sprintf("input['%s']", ns("show_archived")),
          shiny::p(class = "hint", "Archived runs keep every file but drop out of the lists above. Restore one to see its details and use it again."),
          shiny::actionButton(ns("restore"), "Restore", class = "btn-outline-secondary")
        ),
        shiny::hr(),
        shiny::fileInput(ns("import"), "Import cloud results (dragonfarm-results-*.zip)", accept = ".zip", width = "100%"),
        shiny::uiOutput(ns("import_hint"))
      ),
      bslib::card(
        bslib::card_header("Loss"),
        # Fixed-height wrapper: the card stretches to match the taller Runs
        # card beside it, and a bare plotly output would grow to fill it.
        shiny::div(style = "height: 320px;", plotly::plotlyOutput(ns("loss"), height = "100%"))
      )
    ),
    bslib::layout_columns(
      col_widths = c(6, 6),
      bslib::card(
        bslib::card_header("Trainer log"),
        shiny::verbatimTextOutput(ns("log"), placeholder = TRUE)
      ),
      bslib::card(
        bslib::card_header("R code for this run"),
        shiny::verbatimTextOutput(ns("code"), placeholder = TRUE)
      )
    ),
    bslib::layout_columns(
      col_widths = c(4, 8),
      bslib::card(
        bslib::card_header("Task metrics"),
        shiny::p(class = "hint", "Generates a reply for every held-out row and scores it with deterministic checks: exact match, token overlap, JSON validity, numeric answers, and length."),
        shiny::checkboxGroupInput(ns("metric_names"), NULL,
                                  choices = c("exact", "contains", "token_f1", "json_valid", "numeric", "length_ratio"),
                                  selected = c("exact", "token_f1", "length_ratio"), inline = TRUE),
        shiny::actionButton(ns("run_metrics"), "Evaluate held-out rows", class = "btn-outline-primary"),
        shiny::uiOutput(ns("metrics_out"))
      ),
      bslib::card(
        bslib::card_header("Compare runs"),
        shiny::p(class = "hint", "Every run in this directory with whatever has been measured for it: loss, preference accuracy, task metrics, and the latest judge result from the Try it panel."),
        shiny::div(class = "table-wrap", shiny::tableOutput(ns("compare")))
      )
    )
  )
}

mod_monitor_server <- function(id, state, runs_dir) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns
    active_runs <- shiny::reactivePoll(3000, session,
      checkFunc = function() runs_change_signature(runs_dir),
      valueFunc = function() dragon_runs(runs_dir)
    )
    archived_runs_poll <- shiny::reactivePoll(3000, session,
      checkFunc = function() runs_change_signature(file.path(runs_dir, "archived")),
      valueFunc = function() dragon_archived_runs(runs_dir)
    )
    runs <- shiny::reactive(if (isTRUE(input$show_archived)) archived_runs_poll() else active_runs())

    # Resend the choices only when the list itself changed. Resending an
    # unchanged list also resent the server's last-known selection, which
    # could undo a run the user had just picked but the server not yet seen.
    sent <- new.env()
    shiny::observe({
      df <- runs()
      archived <- isTRUE(input$show_archived)
      selected <- shiny::isolate(input$run)
      if (!archived && !is.null(state$run) && state$run$id %in% df$id && !identical(selected, state$run$id)) {
        selected <- state$run$id
      }
      labels <- if (nrow(df)) sprintf("%s  [%s]", df$id, if (archived) "archived" else df$state) else character()
      key <- paste(archived, paste(df$id, labels, collapse = "|"))
      if (identical(key, sent$key) && identical(selected, shiny::isolate(input$run))) return()
      sent$key <- key
      shiny::updateSelectInput(session, "run", choices = stats::setNames(df$id, labels),
                               selected = if (!is.null(selected) && selected %in% df$id) selected else df$id[1])
    })
    shiny::observeEvent(state$run, {
      shiny::updateSelectInput(session, "run", selected = state$run$id)
    })

    # NULL when nothing is selected. Poll check functions must never throw
    # (a req() inside one closes the session), so they use this rather than run().
    current_run <- shiny::reactive({
      id <- input$run
      if (is.null(id) || !nzchar(id)) return(NULL)
      dir <- file.path(runs_dir, id)
      if (!file.exists(file.path(dir, "config.json"))) return(NULL)
      # Reuse the live handle when this is the run we launched, so a crash is detected quickly.
      if (!is.null(state$run) && identical(state$run$id, id)) state$run else dragon_run(dir)
    })
    run <- shiny::reactive({
      r <- current_run()
      shiny::req(r)
      r
    })

    file_sig <- function(path) {
      if (!file.exists(path)) return("")
      info <- file.info(path)
      paste(info$mtime, info$size)
    }
    run_file_sig <- function(name) {
      r <- current_run()
      if (is.null(r)) return("")
      paste(r$id, file_sig(file.path(r$dir, name)))
    }
    progress <- shiny::reactivePoll(1000, session,
      checkFunc = function() run_file_sig("progress.jsonl"),
      valueFunc = function() { r <- current_run(); if (is.null(r)) dragon_progress_empty() else dragon_progress(r) }
    )
    status <- shiny::reactivePoll(1000, session,
      checkFunc = function() paste(run_file_sig("status.json"), as.numeric(Sys.time()) %/% 5),
      valueFunc = function() { r <- current_run(); if (is.null(r)) list(state = "none") else dragon_status(r) }
    )
    logs <- shiny::reactivePoll(1500, session,
      checkFunc = function() run_file_sig("log.txt"),
      valueFunc = function() { r <- current_run(); if (is.null(r)) character() else dragon_logs(r, 40) }
    )

    output$facts <- shiny::renderUI({
      r <- run()
      st <- status()
      cfg <- run_config(r)
      pr <- progress()
      last_loss <- if (nrow(pr) && any(!is.na(pr$loss))) sprintf("%.3f", utils::tail(pr$loss[!is.na(pr$loss)], 1)) else "-"
      step <- if (nrow(pr)) max(pr$step, na.rm = TRUE) else 0
      eta <- if (nrow(pr) && any(!is.na(pr$eta_s))) {
        s <- utils::tail(pr$eta_s[!is.na(pr$eta_s)], 1)
        sprintf("%d min %02d s", s %/% 60, round(s %% 60))
      } else "-"
      shiny::tagList(
        shiny::div(class = "kv", shiny::span("State"), state_pill(st$state)),
        shiny::div(class = "kv", shiny::span("Model"), shiny::code(cfg$model$id)),
        shiny::div(class = "kv", shiny::span("Stage"), shiny::strong(
          if (identical(cfg$stage, "prefer")) sprintf("%s, beta %s", toupper(cfg$prefer$method), cfg$prefer$beta)
          else if (identical(cfg$stage, "reinforce")) sprintf("GRPO, %d rewards", length(cfg$reinforce$rewards))
          else "fine-tune")),
        if (!is.null(cfg$model$base_run)) shiny::div(class = "kv", shiny::span("Continues"), shiny::code(cfg$model$base_run)),
        shiny::div(class = "kv", shiny::span("Device"), shiny::strong(st$device %||% "-")),
        shiny::div(class = "kv", shiny::span("Step"), shiny::strong(sprintf("%d / %s", as.integer(step), st$total_steps %||% "?"))),
        shiny::div(class = "kv", shiny::span("Loss"), shiny::strong(last_loss)),
        shiny::div(class = "kv", shiny::span("ETA"), shiny::strong(eta)),
        if (!is.null(st$pref_accuracy)) shiny::div(class = "kv", shiny::span("Pref. accuracy"), shiny::strong(sprintf("%.0f%% (margin %.3f)", 100 * st$pref_accuracy, st$reward_margin))),
        if (!is.null(st$reward_mean)) shiny::div(class = "kv", shiny::span("Held-out reward"), shiny::strong(sprintf("%.3f", st$reward_mean))),
        if (!is.null(st$eval_loss) && is.null(st$pref_accuracy)) shiny::div(class = "kv", shiny::span("Eval loss"), shiny::strong(sprintf("%.3f (ppl %.2f)", st$eval_loss, st$perplexity))),
        if (!is.null(st$eval_warning)) shiny::div(class = "alert alert-warning py-1 px-2 small mt-2", st$eval_warning),
        if (!is.null(st$error)) shiny::pre(class = "error-box", error_message(st$error, st$error_code))
      )
    })

    output$loss <- plotly::renderPlotly({
      pr <- progress()
      train <- pr[!is.na(pr$loss), , drop = FALSE]
      ev <- pr[!is.na(pr$eval_loss), , drop = FALSE]
      p <- plotly::plot_ly()
      if (!nrow(train) && !nrow(ev)) {
        # An empty scatter trace keeps plotly quiet about a plot with no data.
        p <- plotly::add_trace(p, x = numeric(), y = numeric(), type = "scatter", mode = "lines", showlegend = FALSE)
      }
      if (nrow(train)) {
        p <- plotly::add_trace(p, x = train$step, y = train$loss, type = "scatter", mode = "lines",
                               name = "train loss", line = list(color = "#FF6B35", width = 2.5, shape = "spline"),
                               fill = "tozeroy", fillcolor = "rgba(255, 107, 53, 0.08)")
      }
      if (nrow(ev)) {
        p <- plotly::add_trace(p, x = ev$step, y = ev$eval_loss, type = "scatter", mode = "markers+lines",
                               name = "eval loss", marker = list(color = "#2F6F8F", size = 9, line = list(color = "#FFFFFF", width = 1.5)),
                               line = list(color = "#2F6F8F", dash = "dot"))
      }
      rw <- if ("reward" %in% names(pr)) pr[!is.na(pr$reward), , drop = FALSE] else pr[0, , drop = FALSE]
      if (nrow(rw)) {
        p <- plotly::add_trace(p, x = rw$step, y = rw$reward, type = "scatter", mode = "lines+markers",
                               name = "mean reward", yaxis = "y2", line = list(color = "#3D7A4E", width = 2),
                               marker = list(color = "#3D7A4E", size = 5))
      }
      if (!nrow(train) && !nrow(ev)) {
        p <- plotly::layout(p, annotations = list(text = "Waiting for the first logged step", showarrow = FALSE, x = 0.5, y = 0.5, xref = "paper", yref = "paper"))
      }
      plotly::config(plotly::layout(p,
        xaxis = list(title = "step", zeroline = FALSE, gridcolor = "rgba(138, 147, 168, 0.18)"),
        yaxis = list(title = "loss", zeroline = FALSE, rangemode = "tozero", gridcolor = "rgba(138, 147, 168, 0.18)"),
        font = list(family = "Inter, Segoe UI, sans-serif", color = "#8A93A8", size = 12),
        hoverlabel = list(bgcolor = "#0B1020", bordercolor = "#26324D", font = list(color = "#F1F5FF")),
        yaxis2 = list(title = "reward", overlaying = "y", side = "right", zeroline = FALSE, showgrid = FALSE),
        margin = list(l = 50, r = 20, t = 10, b = 40),
        legend = list(orientation = "h", x = 0, y = 1.1),
        paper_bgcolor = "rgba(0,0,0,0)", plot_bgcolor = "rgba(0,0,0,0)"
      ), displayModeBar = FALSE)
    })

    output$log <- shiny::renderText(paste(logs(), collapse = "\n"))
    output$code <- shiny::renderText({
      r <- run()
      tryCatch(dragon_code(r), error = function(e) conditionMessage(e))
    })

    run_state <- shiny::reactiveVal(NULL)
    shiny::observe(run_state(status()$state %||% "none"))   # unchanged states do not re-render
    output$run_actions <- shiny::renderUI(run_actions_ui(run_state(), ns))

    shiny::observeEvent(input$cancel, {
      r <- run()
      st <- status()
      if (!st$state %in% c("queued", "running")) {
        shiny::showNotification("This run is not running.", type = "warning")
        return()
      }
      writeLines(now_iso(), file.path(r$dir, "cancel.request"))
      shiny::showNotification("Cancel requested. The trainer saves a checkpoint and stops after the current step.", type = "message")
    })

    shiny::observeEvent(input$resume, {
      r <- run()
      res <- tryCatch(dragon_resume(r), error = function(e) { notify_error(e); NULL })
      if (!is.null(res)) {
        state$run <- res
        shiny::showNotification(sprintf("Resumed %s.", res$id), type = "message")
      }
    })

    forget_if_current <- function(id) {
      if (!is.null(state$run) && identical(state$run$id, id)) state$run <- NULL
    }

    shiny::observeEvent(input$archive, {
      r <- run()
      ok <- tryCatch({ dragon_archive_run(r, runs_dir = runs_dir); TRUE }, error = function(e) { notify_error(e); FALSE })
      if (ok) {
        forget_if_current(r$id)
        shiny::showNotification(sprintf("Archived %s.", r$id), type = "message")
      }
    })

    shiny::observeEvent(input$delete, {
      id <- input$run
      shiny::showModal(shiny::modalDialog(
        title = "Delete this run?",
        sprintf("This permanently deletes %s and everything in it: the adapter, checkpoints, samples, and logs. This cannot be undone.", id),
        footer = shiny::tagList(shiny::modalButton("Cancel"), shiny::actionButton(ns("delete_confirm"), "Delete permanently", class = "btn-danger")),
        easyClose = TRUE
      ))
    })
    shiny::observeEvent(input$delete_confirm, {
      r <- run()
      ok <- tryCatch({ dragon_delete_run(r, runs_dir = runs_dir); TRUE }, error = function(e) { notify_error(e); FALSE })
      shiny::removeModal()
      if (ok) {
        forget_if_current(r$id)
        shiny::showNotification(sprintf("Deleted %s.", r$id), type = "message")
      }
    })

    shiny::observeEvent(input$restore, {
      id <- input$run
      ok <- tryCatch({ dragon_unarchive_run(id, runs_dir = runs_dir); TRUE }, error = function(e) { notify_error(e); FALSE })
      if (ok) {
        shiny::updateCheckboxInput(session, "show_archived", value = FALSE)
        shiny::updateSelectInput(session, "run", selected = id)
        shiny::showNotification(sprintf("Restored %s.", id), type = "message")
      }
    })

    shiny::observeEvent(input$run_metrics, {
      r <- run()
      chosen <- input$metric_names
      if (!length(chosen)) {
        shiny::showNotification("Pick at least one metric.", type = "warning")
        return()
      }
      h <- tryCatch(app_task_start(r, dragon_step_evaluate(metrics = chosen), runs_dir, "evaluate"),
                    error = function(e) { notify_error(e); NULL })
      if (is.null(h)) return()
      eval_task(list(id = h$id, state = "running"))
      app_task_watch(h, function(rec) {
        eval_task(list(id = h$id, state = rec$status, error = task_error(rec)))
        if (identical(rec$status, "succeeded")) shiny::showNotification("Metrics saved to the run.", type = "message")
      })
    })

    eval_task <- shiny::reactiveVal(NULL)
    output$metrics_out <- shiny::renderUI({
      st <- status()
      m <- st$metrics
      note <- task_status_ui(eval_task(), "Evaluation")
      if (is.null(m) || !length(m)) return(note)
      shiny::tagList(note, lapply(names(m), function(nm) {
        shiny::div(class = "kv", shiny::span(nm), shiny::strong(formatC(as.numeric(m[[nm]]), digits = 3, format = "fg")))
      }))
    })

    output$compare <- shiny::renderTable({
      # The run-list poll already changes when any run's status or progress
      # file does; status() also ticks every 5 s, which rebuilt this table
      # (0.4 s with 40 runs) on every tick.
      runs()
      cmp <- tryCatch(dragon_compare(runs_dir = runs_dir), error = function(e) NULL)
      if (is.null(cmp) || !nrow(cmp)) return(data.frame(note = "No runs yet."))
      df <- as.data.frame(cmp)
      df$model <- basename(df$model)
      df$from <- ifelse(is.na(df$from), "", df$from)
      df$method <- ifelse(is.na(df$method), "", df$method)
      df$run <- df$id
      df$id <- NULL
      keep <- vapply(df, function(col) is.character(col) || any(!is.na(col)), logical(1))
      df <- df[, c("run", setdiff(names(df)[keep], "run")), drop = FALSE]
      df
    }, spacing = "xs", width = "100%", na = "", digits = 3)

    output$import_hint <- shiny::renderUI({
      st <- status()
      if (!identical(st$state, "bundled")) return(NULL)
      shiny::p(class = "hint", "This run was bundled for a cloud GPU. Train it there, then drop the results zip above.")
    })

    shiny::observeEvent(input$import, {
      r <- run()
      f <- input$import
      shiny::req(f)
      res <- tryCatch(dragon_import(r, f$datapath), error = function(e) { notify_error(e); NULL })
      if (!is.null(res)) {
        st <- dragon_status(res)
        shiny::showNotification(sprintf("Imported results for %s (%s).", res$id, st$state), type = "message")
      }
    })
  })
}

# The run-control buttons for a run in a given state.
run_actions_ui <- function(state, ns = identity) {
  state <- state %||% "none"
  shiny::tagList(
    if (state %in% c("running", "queued"))
      shiny::actionButton(ns("cancel"), "Cancel run", class = "btn-outline-danger", width = "100%"),
    if (state %in% c("failed", "cancelled"))
      shiny::actionButton(ns("resume"), "Resume from checkpoint", class = "btn-outline-secondary", width = "100%")
  )
}
