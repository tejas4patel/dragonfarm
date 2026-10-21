mod_monitor_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_columns(
      col_widths = c(4, 8),
      bslib::card(
        bslib::card_header("Runs"),
        shiny::checkboxInput(ns("show_archived"), "Show archived", value = FALSE),
        shiny::selectInput(ns("run"), shiny::tags$span(class = "visually-hidden", "Run"), choices = character(), width = "100%"),
        shiny::uiOutput(ns("facts")),
        shiny::uiOutput(ns("space")),
        shiny::conditionalPanel(
          condition = sprintf("!input['%s']", ns("show_archived")),
          # Cancel while a run is going, Resume once it stopped short; neither
          # for a finished run (both used to show for every run).
          shiny::uiOutput(ns("run_actions")),
          shiny::div(class = "cloud-actions", style = "margin-top: 8px;",
            shiny::actionButton(ns("archive"), "Archive", class = "btn-outline-secondary"),
            shiny::actionButton(ns("delete"), "Delete", class = "btn-outline-danger"),
            shiny::downloadButton(ns("provenance"), "Provenance", class = "btn-outline-secondary")
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
        scroll_box(shiny::verbatimTextOutput(ns("log"), placeholder = TRUE), "Trainer log")
      ),
      bslib::card(
        bslib::card_header("R code for this run"),
        scroll_box(shiny::verbatimTextOutput(ns("code"), placeholder = TRUE), "R code for this run")
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
    ),
    bslib::card(
      bslib::card_header("Waiting for you"),
      shiny::p(class = "hint", "Things an agent asked to do that need a person first: training, and anything that deletes or leaves this machine. Approve one and it runs now, in your name; decline it and it never runs."),
      shiny::div(class = "table-wrap", shiny::tableOutput(ns("approvals"))),
      bslib::layout_columns(
        col_widths = c(4, 8),
        shiny::selectInput(ns("approval_pick"), "Request", choices = c("Pick a request" = ""), width = "100%"),
        shiny::textInput(ns("approval_note"), "Note (optional)", width = "100%")
      ),
      shiny::div(class = "btn-row",
        shiny::actionButton(ns("approve"), "Approve and run", class = "btn-primary"),
        shiny::actionButton(ns("decline"), "Decline", class = "btn-outline-secondary"))
    ),
    bslib::card(
      bslib::card_header("Activity"),
      shiny::p(class = "hint", "Everything the tools and agents did, newest first: each call, whether it worked, and why not. Calls an agent was refused and calls waiting for a person are kept too."),
      shiny::uiOutput(ns("summary7")),
      shiny::radioButtons(ns("activity_filter"), NULL, inline = TRUE,
                          choices = c("Everything" = "all", "Refused or failed" = "failed", "Waiting for approval" = "approval")),
      shiny::div(class = "table-wrap", shiny::tableOutput(ns("activity"))),
      shiny::selectInput(ns("activity_pick"), "Details of", choices = c("Pick an entry" = ""), width = "100%"),
      shiny::uiOutput(ns("activity_trace")),
      scroll_box(shiny::verbatimTextOutput(ns("activity_detail"), placeholder = TRUE), "Details of the selected entry"),
      shiny::uiOutput(ns("replay_ui")),
      shiny::div(class = "btn-row", shiny::downloadButton(ns("export_record"), "Download the record (CSV)", class = "btn-outline-secondary btn-sm"),
                 shiny::downloadButton(ns("export_traces"), "Traces for your monitoring tools (7 days)", class = "btn-outline-secondary btn-sm"))
    ),
    bslib::card(
      bslib::card_header("Model versions"),
      shiny::p(class = "hint", "Turn a finished, evaluated run into a numbered version of a named model, then sign it off: approve it for a stated use, reject it, or retire it later. Only a person signs, and nothing here can be edited afterwards."),
      bslib::layout_columns(
        col_widths = c(6, 6),
        shiny::textInput(ns("reg_name"), "Model name", placeholder = "support-bot", width = "100%"),
        shiny::div(class = "btn-row", shiny::actionButton(ns("reg_propose"), "Propose the selected run", class = "btn-outline-primary"))
      ),
      shiny::div(class = "table-wrap", shiny::tableOutput(ns("registry"))),
      bslib::layout_columns(
        col_widths = c(4, 4, 4),
        shiny::selectInput(ns("reg_pick"), "Version", choices = c("Pick a version" = ""), width = "100%"),
        shiny::selectInput(ns("reg_decision"), "Decision", choices = c("Approve" = "approved", "Reject" = "rejected", "Retire" = "retired"), width = "100%"),
        shiny::textInput(ns("reg_meaning"), "What it means", placeholder = "Approved for answering support tickets", width = "100%")
      ),
      shiny::uiOutput(ns("reg_findings")),
      shiny::actionButton(ns("reg_sign"), "Sign", class = "btn-primary")
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
      checkFunc = function() archived_runs_signature(runs_dir),
      valueFunc = function() dragon_archived_runs(runs_dir)
    )
    runs <- shiny::reactive(if (isTRUE(input$show_archived)) archived_runs_poll() else active_runs())

    # The catalogue's event log, re-read only when a new event lands.
    events <- shiny::reactivePoll(3000, session,
      checkFunc = function() tryCatch(store_get(store_open(runs_dir), "SELECT MAX(id) AS m FROM events")$m, error = function(e) NA),
      valueFunc = function() tryCatch(store_events(200L, runs_dir = runs_dir), error = function(e) NULL)
    )
    shown_events <- shiny::reactive({
      ev <- events()
      if (is.null(ev) || !nrow(ev)) return(ev)
      switch(input$activity_filter %||% "all",
             failed = ev[!is.na(ev$ok) & ev$ok == 0 & ev$kind != "approval_request", , drop = FALSE],
             approval = ev[ev$kind == "approval_request", , drop = FALSE],
             ev)
    })
    # The approvals inbox, refreshed with the event log.
    pending <- shiny::reactive({
      events()
      tryCatch(approvals_pending(runs_dir), error = function(e) NULL)
    })
    output$approvals <- shiny::renderTable({
      p <- pending()
      if (is.null(p)) return(data.frame(Note = "The catalogue could not be read."))
      approvals_table(p)
    })
    shiny::observe({
      p <- pending()
      choices <- if (is.null(p) || !nrow(p)) character() else stats::setNames(as.character(p$id), sprintf("#%s %s", p$id, p$name))
      shiny::updateSelectInput(session, "approval_pick", choices = c("Pick a request" = "", choices))
    })
    decide <- function(approve) {
      id <- input$approval_pick
      if (is.null(id) || !nzchar(id)) { shiny::showNotification("Pick a request first.", type = "warning"); return() }
      note <- trimws(input$approval_note %||% "")
      res <- tryCatch(approval_decide(as.integer(id), approve, note = if (nzchar(note)) note, runs_dir = runs_dir),
                      error = function(e) { notify_error(e); NULL })
      if (is.null(res)) return()
      msg <- if (!approve) sprintf("Request #%s declined.", id)
             else if (isTRUE(res$ok)) sprintf("Request #%s approved and run.", id)
             else sprintf("Request #%s approved, but the call failed: %s", id, error_message(res$error, res$code))
      shiny::showNotification(msg, type = if (approve && !isTRUE(res$ok)) "error" else "message")
      shiny::updateTextInput(session, "approval_note", value = "")
    }
    shiny::observeEvent(input$approve, decide(TRUE))
    shiny::observeEvent(input$decline, decide(FALSE))

    output$activity <- shiny::renderTable({
      ev <- shown_events()
      if (is.null(ev) || !nrow(ev)) return(data.frame(Note = "Nothing recorded yet."))
      data.frame(When = sub("T", " ", sub("Z$", "", ev$at)), What = ev$kind, Name = ev$name %||% "",
                 Worked = ifelse(is.na(ev$ok), "", ifelse(ev$ok == 1, "yes", "no")), Code = ifelse(is.na(ev$code), "", ev$code),
                 `Took (ms)` = ifelse(is.na(ev$duration_ms), "", ev$duration_ms), check.names = FALSE)
    })
    shiny::observe({
      ev <- shown_events()
      choices <- if (is.null(ev) || !nrow(ev)) character() else stats::setNames(as.character(ev$id), sprintf("#%s %s %s", ev$id, ev$kind, ev$name %||% ""))
      shiny::updateSelectInput(session, "activity_pick", choices = c("Pick an entry" = "", choices))
    })
    # The last 7 days at a glance, from the record.
    output$summary7 <- shiny::renderUI({
      events()
      sm <- tryCatch(store_summary(7, runs_dir), error = function(e) NULL)
      if (is.null(sm) || !length(sm$kinds)) return(NULL)
      line <- function(tab) paste(sprintf("%s %d", names(tab), as.integer(tab)), collapse = ", ")
      shiny::div(class = "summary7 small",
        shiny::p(shiny::strong("Last 7 days: "), line(sm$kinds)),
        if (length(sm$problems)) shiny::p(shiny::strong("Refused or failed: "), line(sm$problems)),
        if (nrow(sm$outbound)) shiny::p(shiny::strong("Left this machine: "),
          paste(sprintf("%s (%d calls, %s)", sm$outbound$host, sm$outbound$calls,
                        format(structure(sm$outbound$bytes, class = "object_size"), units = "auto")), collapse = "; ")),
        if (isTRUE(sm$agents$routed > 0)) shiny::p(shiny::strong("Agents: "),
          sprintf("%d task%s, %d handed to the fixed workflow", sm$agents$routed, if (sm$agents$routed == 1) "" else "s",
                  sm$agents$fell_back)),
        if (sm$waiting) shiny::p(shiny::strong(sprintf("Waiting for you: %d", sm$waiting))))
    })

    # The last week as OpenTelemetry traces (OTLP JSON), for a company's
    # observability tools; the export is recorded.
    output$export_traces <- shiny::downloadHandler(
      filename = function() sprintf("dragonfarm-traces-%s.json", format(Sys.time(), "%Y%m%d-%H%M%S")),
      content = function(file) store_export_otlp(file, days = 7, runs_dir = runs_dir),
      contentType = "application/json"
    )

    # Where the selected run came from, as a short Markdown report.
    output$provenance <- shiny::downloadHandler(
      filename = function() sprintf("provenance-%s.md", input$run %||% "run"),
      content = function(file) provenance_write(run(), file, runs_dir = runs_dir),
      contentType = "text/markdown"
    )

    # The record as a file for an auditor: every table of the catalogue with
    # a manifest of fingerprints; the export itself is recorded.
    output$export_record <- shiny::downloadHandler(
      filename = function() sprintf("dragonfarm-record-%s.zip", format(Sys.time(), "%Y%m%d-%H%M%S")),
      content = function(file) store_export_all(file, runs_dir = runs_dir),
      contentType = "application/zip"
    )

    # Replay a recorded read-only call, answer or agent task and say whether it matches.
    replay_result <- shiny::reactiveVal(NULL)
    output$replay_ui <- shiny::renderUI({
      id <- input$activity_pick
      ev <- events()
      if (is.null(id) || !nzchar(id) || is.null(ev)) return(NULL)
      row <- ev[as.character(ev$id) == id, , drop = FALSE]
      if (!nrow(row) || !row$kind %in% c("tool", "agent_run", "ask") || !identical(as.integer(row$ok), 1L)) return(NULL)
      r <- replay_result()
      shiny::div(class = "btn-row",
        shiny::actionButton(session$ns("replay"), "Run it again and compare", class = "btn-outline-secondary btn-sm"),
        if (!is.null(r) && identical(r$id, id)) shiny::span(class = paste("small", if (isTRUE(r$matches)) "text-success" else "text-danger"), r$message))
    })
    shiny::observeEvent(input$replay, {
      id <- input$activity_pick
      ev <- events()
      row <- ev[as.character(ev$id) == id, , drop = FALSE]
      replay <- switch(row$kind, agent_run = agent_replay, ask = ask_replay, tool_replay)
      res <- tryCatch(replay(as.integer(id), runs_dir),
                      error = function(e) list(ok = FALSE, error = conditionMessage(e)))
      msg <- if (!isTRUE(res$ok)) paste("Could not replay:", res$error)
             else if (isTRUE(res$matches)) "Same result as before."
             else paste0("Different result", if (length(res$changes)) paste0(": ", paste(res$changes, collapse = "; ")) else " on the same documents and model.")
      replay_result(list(id = id, matches = isTRUE(res$matches), message = msg))
    })

    # Model versions: propose, list, sign off.
    reg_tick <- shiny::reactiveVal(0)
    registry_rows <- shiny::reactive({
      reg_tick(); events()
      tryCatch(registry_list(runs_dir = runs_dir), error = function(e) NULL)
    })
    output$registry <- shiny::renderTable({
      l <- registry_rows()
      if (is.null(l) || !nrow(l)) return(data.frame(Note = "No model versions yet."))
      data.frame(Model = l$name, Version = l$version, Run = l$run_id, Status = l$status,
                 `Signed by` = ifelse(is.na(l$signer), "", l$signer), Meaning = ifelse(is.na(l$meaning), "", l$meaning),
                 check.names = FALSE)
    })
    shiny::observe({
      l <- registry_rows()
      choices <- if (is.null(l) || !nrow(l)) character() else stats::setNames(paste(l$name, l$version, sep = "@"), sprintf("%s v%d (%s)", l$name, l$version, l$status))
      shiny::updateSelectInput(session, "reg_pick", choices = c("Pick a version" = "", choices))
    })
    shiny::observeEvent(input$reg_propose, {
      r <- tryCatch(current_run(), error = function(e) NULL)
      if (is.null(r)) { shiny::showNotification("Pick a run in the Runs card first.", type = "warning"); return() }
      res <- tryCatch(registry_propose(r, trimws(input$reg_name %||% ""), runs_dir = runs_dir), error = function(e) { notify_error(e); NULL })
      if (!is.null(res)) shiny::showNotification(sprintf("%s version %d proposed. A person signs it off below.", res$name, res$version), type = "message")
      reg_tick(reg_tick() + 1)
    })
    # Before you sign: what the record says about the picked version's run.
    output$reg_findings <- shiny::renderUI({
      pick <- input$reg_pick %||% ""
      l <- registry_rows()
      if (!nzchar(pick) || is.null(l)) return(NULL)
      parts <- strsplit(pick, "@", fixed = TRUE)[[1]]
      row <- l[l$name == parts[1] & l$version == as.integer(parts[2]), , drop = FALSE]
      if (!nrow(row)) return(NULL)
      fx <- tryCatch(governance_findings(row$run_id[1], runs_dir = runs_dir), error = function(e) NULL)
      if (is.null(fx)) return(shiny::p(class = "hint small", "The run behind this version is no longer on disk."))
      mark <- c(ok = "\u2713", look = "!", unknown = "?")
      shiny::div(class = "small",
        shiny::tags$h6("Before you sign"),
        shiny::tags$ul(class = "list-unstyled", lapply(seq_len(nrow(fx)), function(i) shiny::tags$li(
          class = if (fx$status[i] == "look") "text-warning",
          shiny::tags$span(`aria-hidden` = "true", mark[[fx$status[i]]]), " ", fx$note[i],
          if (fx$blocks[i]) shiny::strong(" Holds approval until reviewed.")))),
        # D-17: these two hold an approval until the signer says they reviewed them.
        if (any(fx$blocks)) shiny::checkboxInput(ns("reg_reviewed"), "I have reviewed the findings that hold approval; approve anyway", value = FALSE))
    })
    shiny::observeEvent(input$reg_sign, {
      pick <- input$reg_pick %||% ""
      if (!nzchar(pick)) { shiny::showNotification("Pick a version first.", type = "warning"); return() }
      parts <- strsplit(pick, "@", fixed = TRUE)[[1]]
      ok <- tryCatch({ registry_sign_off(parts[1], as.integer(parts[2]), input$reg_decision, meaning = input$reg_meaning %||% "", runs_dir = runs_dir,
                                         reviewed = isTRUE(input$reg_reviewed)); TRUE },
                     error = function(e) { notify_error(e); FALSE })
      if (ok) {
        shiny::showNotification(sprintf("%s version %s: %s.", parts[1], parts[2], input$reg_decision), type = "message")
        shiny::updateTextInput(session, "reg_meaning", value = "")
      }
      reg_tick(reg_tick() + 1)
    })

    # An answer opens to a readable trace; the full record stays below it.
    output$activity_trace <- shiny::renderUI({
      id <- input$activity_pick
      ev <- events()
      if (is.null(id) || !nzchar(id) || is.null(ev)) return(NULL)
      row <- ev[as.character(ev$id) == id, , drop = FALSE]
      if (!nrow(row) || !row$kind %in% c("ask", "agent_run") || is.na(row$detail)) return(NULL)
      d <- jsonlite::fromJSON(row$detail, simplifyVector = FALSE)
      tryCatch(if (identical(row$kind, "ask")) trace_view(d, runs_dir) else agent_trace_view(d, runs_dir), error = function(e) NULL)
    })

    output$activity_detail <- shiny::renderText({
      id <- input$activity_pick
      ev <- events()
      if (is.null(id) || !nzchar(id) || is.null(ev)) return("")
      row <- ev[as.character(ev$id) == id, , drop = FALSE]
      if (!nrow(row) || is.na(row$detail)) return("")
      jsonlite::prettify(row$detail)
    })

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
      r <- run_find(id, runs_dir)
      if (is.null(r)) return(NULL)
      # Reuse the live handle when this is the run we launched, so a crash is detected quickly.
      if (!is.null(state$run) && identical(state$run$id, id)) state$run else r
    })
    run <- shiny::reactive({
      r <- current_run()
      shiny::req(r)
      r
    })

    run_file_sig <- function(name) {
      r <- current_run()
      if (is.null(r)) return("")
      run_file_signature(r, name)
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

    # How much room runs take, the largest first; archive or delete stays a person's call.
    ck_tick <- shiny::reactiveVal(0)
    output$space <- shiny::renderUI({
      ck_tick()
      sp <- tryCatch(runs_space(active_runs()), error = function(e) NULL)
      if (is.null(sp) || !nrow(sp)) return(NULL)
      top <- utils::head(sp, 3)
      fc <- tryCatch(finished_checkpoints(active_runs()), error = function(e) NULL)
      shiny::tagList(
        shiny::p(class = "hint small", sprintf("%s %s. Largest: %s.", if (nrow(sp) == 1) "1 run uses" else sprintf("All %d runs use", nrow(sp)), fmt_bytes(sum(sp$bytes)),
                                               paste(sprintf("%s (%s)", top$id, vapply(top$bytes, fmt_bytes, "")), collapse = ", "))),
        # A proposal, never automatic: removing them is a person's click.
        if (!is.null(fc) && nrow(fc)) shiny::p(class = "hint small",
          sprintf("Checkpoints in %d finished run%s take %s. They are only used to resume a run that stopped; each run keeps its trained adapter. ",
                  nrow(fc), if (nrow(fc) == 1) "" else "s", fmt_bytes(sum(fc$bytes))),
          shiny::actionLink(ns("clean_ck"), "Remove them")))
    })
    shiny::observeEvent(input$clean_ck, {
      fc <- finished_checkpoints(active_runs())
      if (!nrow(fc)) return()
      shiny::showModal(shiny::modalDialog(
        title = "Remove the checkpoints of finished runs?",
        shiny::p(sprintf("This frees %s. The runs, their adapters, samples, logs and evaluations stay; only the saved points to resume training from go. This cannot be undone.", fmt_bytes(sum(fc$bytes)))),
        shiny::tags$ul(lapply(utils::head(seq_len(nrow(fc)), 12), function(i) shiny::tags$li(sprintf("%s (%s)", fc$id[i], fmt_bytes(fc$bytes[i]))))),
        if (nrow(fc) > 12) shiny::p(class = "small", sprintf("and %d more.", nrow(fc) - 12)),
        footer = shiny::tagList(shiny::modalButton("Cancel"), shiny::actionButton(ns("clean_ck_confirm"), "Remove checkpoints", class = "btn-danger")),
        easyClose = TRUE))
    })
    shiny::observeEvent(input$clean_ck_confirm, {
      shiny::removeModal()
      res <- tryCatch(remove_finished_checkpoints(finished_checkpoints(active_runs())$id, runs_dir = runs_dir), error = function(e) { notify_error(e); NULL })
      ck_tick(ck_tick() + 1)
      if (!is.null(res)) shiny::showNotification(sprintf("Removed checkpoints from %d run%s, freeing %s.", length(res$removed),
                                                         if (length(res$removed) == 1) "" else "s", fmt_bytes(res$bytes)), type = "message")
    })

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
        if (!is.null(trained <- trainer_label(st))) shiny::div(class = "kv", shiny::span("Trained with"), shiny::strong(trained)),
        shiny::div(class = "kv", shiny::span("Size on disk"), shiny::strong(fmt_bytes(dir_bytes(r$dir)))),
        shiny::div(class = "kv", shiny::span("Step"), shiny::strong(sprintf("%d / %s", as.integer(step), st$total_steps %||% "?"))),
        shiny::div(class = "kv", shiny::span("Loss"), shiny::strong(last_loss)),
        shiny::div(class = "kv", shiny::span("ETA"), shiny::strong(eta)),
        if (!is.null(st$pref_accuracy)) shiny::div(class = "kv", shiny::span("Pref. accuracy"), shiny::strong(sprintf("%.0f%% (margin %.3f)", 100 * st$pref_accuracy, st$reward_margin))),
        if (!is.null(st$reward_mean)) shiny::div(class = "kv", shiny::span("Held-out reward"), shiny::strong(sprintf("%.3f", st$reward_mean))),
        if (!is.null(st$eval_loss) && is.null(st$pref_accuracy)) shiny::div(class = "kv", shiny::span("Eval loss"), shiny::strong(sprintf("%.3f (ppl %.2f)", st$eval_loss, st$perplexity))),
        if (!is.null(st$eval_warning)) shiny::div(class = "alert alert-warning py-1 px-2 small mt-2", st$eval_warning),
        if (!is.null(stalled <- run_stalled(r, st))) shiny::div(class = "alert alert-warning py-1 px-2 small mt-2",
          sprintf("No progress for %d minutes. If the computer slept, keep it awake and plugged in; otherwise read the trainer log below, or cancel the run.", stalled)),
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
      run_request_cancel(r)
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
      impact <- tryCatch(deletion_impact(run = run(), runs_dir = runs_dir)$note, error = function(e) NULL)
      shiny::showModal(shiny::modalDialog(
        title = "Delete this run?",
        shiny::p(sprintf("This permanently deletes %s and everything in it: the adapter, checkpoints, samples, and logs. This cannot be undone.", id)),
        if (!is.null(impact)) shiny::p(impact),
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

# A scrolling text box keyboard users can reach and scroll (WCAG 2.1.1).
scroll_box <- function(tag, label) {
  shiny::tagAppendAttributes(tag, tabindex = "0", role = "region", `aria-label` = label)
}
