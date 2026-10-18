# Backend picker, reused for the primary conversation and (in compare
# mode) a second one to answer the same messages side by side.
chat_backend_inputs <- function(ns, suffix, title) {
  bslib::card(
    bslib::card_header(title),
    shiny::selectInput(ns(paste0("source", suffix)), "Backend", width = "100%",
      choices = c("A run on this machine" = "run", "Ollama on this machine" = "ollama", "OpenAI-compatible server" = "server")),
    shiny::conditionalPanel(
      condition = sprintf("input['%s'] == 'run'", ns(paste0("source", suffix))),
      shiny::selectInput(ns(paste0("run", suffix)), label_with_info("Run", "answer"), choices = character(), width = "100%"),
      shiny::checkboxInput(ns(paste0("base", suffix)), "Talk to what it started from instead", value = FALSE)
    ),
    shiny::conditionalPanel(
      condition = sprintf("input['%s'] == 'ollama'", ns(paste0("source", suffix))),
      shiny::textInput(ns(paste0("ollama_model", suffix)), "Ollama model name", placeholder = "dragonfarm-20260914-support", width = "100%"),
      shiny::textInput(ns(paste0("ollama_url", suffix)), "Ollama URL", value = "http://localhost:11434", width = "100%")
    ),
    shiny::conditionalPanel(
      condition = sprintf("input['%s'] == 'server'", ns(paste0("source", suffix))),
      shiny::textInput(ns(paste0("server_url", suffix)), "Server URL (ending in /v1)", placeholder = "https://host/v1", width = "100%"),
      shiny::textInput(ns(paste0("server_model", suffix)), "Model name on the server", width = "100%"),
      shiny::passwordInput(ns(paste0("server_key", suffix)), "API key (optional)", width = "100%")
    )
  )
}

mod_chat_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::layout_columns(
    col_widths = c(4, 8),
    shiny::div(
      chat_backend_inputs(ns, "", "Who answers"),
      bslib::card(
        bslib::card_header("Settings"),
        shiny::textAreaInput(ns("system"), "System prompt (optional)", rows = 3, width = "100%",
                             placeholder = "You are a concise support agent for a smart-home company."),
        bslib::layout_columns(
          col_widths = c(6, 6),
          shiny::numericInput(ns("temperature"), "Temperature", value = 0.7, min = 0, max = 2, step = 0.1),
          shiny::numericInput(ns("max_new_tokens"), "Max new tokens", value = 600, min = 1, step = 16)
        ),
        shiny::numericInput(ns("context_window"), "Context window (tokens, optional)", value = NA, min = 64, step = 64),
        shiny::p(class = "hint", "Leave blank for no limit. When set, the oldest turns are dropped automatically to stay under it."),
        shiny::selectInput(ns("documents"), "Answer from documents", choices = c("No, plain conversation" = ""), width = "100%"),
        shiny::p(class = "hint", "Document sets made with dragon_documents(). Each turn is answered from the most relevant excerpts, with sources under the reply."),
        shiny::checkboxInput(ns("compare"), "Compare with a second backend", value = FALSE)
      ),
      shiny::conditionalPanel(condition = sprintf("input['%s']", ns("compare")), chat_backend_inputs(ns, "_b", "Second backend")),
      shiny::div(class = "cloud-actions",
        shiny::actionButton(ns("new"), "New conversation", class = "btn-outline-secondary"),
        shiny::downloadButton(ns("save"), "Save transcript", class = "btn-outline-primary")
      ),
      shiny::div(class = "cloud-actions", style = "margin-top: 8px;",
        shiny::downloadButton(ns("export_example"), "Export as training example", class = "btn-outline-secondary")
      ),
      shiny::fileInput(ns("load"), "Load transcript", accept = ".json", width = "100%"),
      shiny::p(class = "hint", "The whole conversation is sent on every turn, so the model keeps context. The local worker keeps the model loaded between turns.")
    ),
    shiny::div(
      shiny::uiOutput(ns("context_banner")),
      shiny::uiOutput(ns("panes")),
      shiny::div(class = "chat-compose",
        shiny::textAreaInput(ns("text"), shiny::tags$span(class = "visually-hidden", "Message"), rows = 2, width = "100%", placeholder = "Type a message"),
        shiny::actionButton(ns("send"), "Send", class = "btn-primary")
      )
    ),
    # A reply from the local worker or a server streams token by token; this
    # writes those tokens straight into the DOM as they arrive, bypassing
    # Shiny's own reactive flush (which only happens after $say() returns,
    # since it runs synchronously inside the click handler). The real bubble
    # takes over once history() updates at the end of the turn.
    shiny::tags$script(shiny::HTML(sprintf(
      "Shiny.addCustomMessageHandler('%s', function(msg) {
         var bubble = document.getElementById('%s'), content = document.getElementById('%s');
         if (!bubble || !content) return;
         if (msg.reset) content.textContent = '';
         if (msg.text) content.textContent += msg.text;
         bubble.style.display = msg.hide ? 'none' : 'block';
         bubble.scrollIntoView({block: 'end'});
       });",
      ns("stream"), ns("streaming_bubble"), ns("streaming_content")
    )))
  )
}

mod_chat_server <- function(id, state, runs_dir) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns
    stream_type <- ns("stream")
    # Pushed straight to the client, bypassing Shiny's reactive flush, so the
    # primary reply's tokens appear as they arrive rather than all at once
    # when $say() finally returns. reset() clears and shows the streaming
    # bubble; a token appends to it; hide() lets the settled reply (now part
    # of history()) take over.
    # tryCatch: a streaming glitch (or a test session that does not support
    # sendCustomMessage) should never break sending or receiving a reply.
    stream_msg <- function(...) tryCatch(session$sendCustomMessage(stream_type, list(...)), error = function(e) NULL)

    runs <- shiny::reactivePoll(4000, session,
      checkFunc = function() runs_change_signature(runs_dir),
      valueFunc = function() {
        df <- dragon_runs(runs_dir)
        df[file.exists(file.path(df$dir, "adapter", "adapter_config.json")), , drop = FALSE]
      }
    )
    shiny::observe({
      df <- runs()
      labels <- if (nrow(df)) sprintf("%s  [%s]", df$id, df$stage) else character()
      for (suffix in c("run", "run_b")) {
        selected <- shiny::isolate(input[[suffix]])
        if (suffix == "run" && !is.null(state$run) && state$run$id %in% df$id && (is.null(selected) || !nzchar(selected))) selected <- state$run$id
        shiny::updateSelectInput(session, suffix, choices = stats::setNames(df$id, labels),
                                 selected = if (!is.null(selected) && selected %in% df$id) selected else df$id[1])
      }
    })

    # The conversation is rebuilt when the backend or settings change; the
    # history is kept in a plain list so it survives that. A second,
    # independent history exists only when "compare" is on.
    history <- shiny::reactiveVal(list())
    chat_obj <- shiny::reactiveVal(NULL)
    context_info <- shiny::reactiveVal(NULL)
    history_b <- shiny::reactiveVal(list())
    chat_obj_b <- shiny::reactiveVal(NULL)

    backend_for <- function(suffix) {
      src <- input[[paste0("source", suffix)]] %||% "run"
      switch(src,
        ollama = {
          m <- trimws(input[[paste0("ollama_model", suffix)]] %||% "")
          if (nzchar(m)) dragon_backend_ollama(m, url = input[[paste0("ollama_url", suffix)]] %||% "http://localhost:11434")
        },
        server = {
          u <- trimws(input[[paste0("server_url", suffix)]] %||% "")
          mo <- trimws(input[[paste0("server_model", suffix)]] %||% "")
          if (nzchar(u) && nzchar(mo)) dragon_backend_server(u, mo, api_key = input[[paste0("server_key", suffix)]] %||% "")
        },
        dragon_backend_local()
      )
    }
    backend <- shiny::reactive(backend_for(""))
    backend_b <- shiny::reactive(backend_for("_b"))

    context_window_input <- function() {
      cw <- input$context_window
      if (is.null(cw) || is.na(cw) || cw < 64) return(NULL)
      as.integer(cw)
    }

    build_chat_for <- function(suffix, bk, hist) {
      if (is.null(bk)) return(NULL)
      x <- NULL
      if (!is_server_backend(bk)) {
        run_id <- input[[paste0("run", suffix)]]
        if (is.null(run_id) || !nzchar(run_id)) return(NULL)
        x <- dragon_run(file.path(runs_dir, run_id))
      }
      sys <- if (nzchar(trimws(input$system %||% ""))) input$system
      docs <- documents_choice()
      ch <- dragon_chat(x, system = sys, backend = bk, max_new_tokens = input$max_new_tokens %||% 600,
                        temperature = input$temperature %||% 0.7, base = isTRUE(input[[paste0("base", suffix)]]),
                        runs_dir = runs_dir, context_window = context_window_input(), documents = docs)
      ch$messages <- hist
      ch
    }

    # Document sets available for "Answer from documents": refreshed whenever
    # the runs directory changes, since sets live under runs_dir/documents.
    shiny::observe({
      runs()   # re-list when anything under runs_dir changes
      sets <- tryCatch(dragon_documents_list(runs_dir), error = function(e) NULL)
      choices <- c("No, plain conversation" = "")
      if (!is.null(sets) && nrow(sets)) choices <- c(choices, stats::setNames(sets$dir, sprintf("%s (%d chunks)", sets$name, sets$chunks)))
      # Prefer the set open on the Documents tab ("Continue in Chat"), else keep the user's pick.
      open <- state$documents
      selected <- if (!is.null(open) && open$dir %in% choices) open$dir else shiny::isolate(input$documents) %||% ""
      shiny::updateSelectInput(session, "documents", choices = choices, selected = selected)
    })
    documents_choice <- function() {
      d <- input$documents
      if (is.null(d) || !nzchar(d)) return(NULL)
      tryCatch(dragon_documents_load(d), error = function(e) { notify_error(e); NULL })
    }
    # Sources behind each assistant reply, keyed by its position in the history.
    sources_by_index <- shiny::reactiveVal(list())
    build_chat <- function() build_chat_for("", backend(), history())
    build_chat_b <- function() build_chat_for("_b", backend_b(), history_b())

    output$title <- shiny::renderUI({
      b <- backend()
      if (is.null(b)) return("Conversation")
      what <- if (is_server_backend(b)) b$model else input$run %||% ""
      shiny::span("Conversation with ", shiny::code(what), shiny::span(class = "text-muted small", paste0("  via ", backend_label(b))))
    })
    output$title_b <- shiny::renderUI({
      b <- backend_b()
      if (is.null(b)) return("Second conversation")
      what <- if (is_server_backend(b)) b$model else input$run_b %||% ""
      shiny::span("Also with ", shiny::code(what), shiny::span(class = "text-muted small", paste0("  via ", backend_label(b))))
    })

    output$context_banner <- shiny::renderUI({
      info <- context_info()
      if (is.null(info) || !isTRUE(info$near_limit)) return(NULL)
      shiny::div(class = "alert alert-warning context-banner",
        sprintf("Using about %d of %d tokens (%.0f%%)%s.", info$tokens, info$window, 100 * info$ratio,
                if (info$dropped_turns > 0) sprintf(", %d turn%s dropped to stay under the limit", info$dropped_turns, if (info$dropped_turns != 1) "s" else "") else ""))
    })

    shiny::observeEvent(input$send, {
      text <- trimws(input$text %||% "")
      if (!nzchar(text)) return()
      ch <- tryCatch(build_chat(), error = function(e) { notify_error(e); NULL })
      if (is.null(ch)) {
        shiny::showNotification("Pick a backend first: a run, an Ollama model, or a server.", type = "warning")
        return()
      }
      shiny::updateTextAreaInput(session, "text", value = "")
      history(c(history(), list(list(role = "user", content = text))))
      stream_msg(reset = TRUE)
      shiny::withProgress(message = "Thinking", value = 0.5, {
        reply <- tryCatch(ch$say(text, on_token = function(piece) stream_msg(text = piece)),
                          error = function(e) { notify_error(e); NULL })
      })
      stream_msg(hide = TRUE)
      if (is.null(reply)) {
        h <- history()
        history(h[seq_len(length(h) - 1)])   # drop the unanswered user turn
        return()
      }
      history(ch$history())
      chat_obj(ch)
      context_info(ch$context_usage())
      src <- ch$sources()
      if (!is.null(src) && nrow(src)) {
        s <- sources_by_index(); s[[as.character(length(ch$history()))]] <- src; sources_by_index(s)
      }

      if (isTRUE(input$compare)) {
        chb <- tryCatch(build_chat_b(), error = function(e) { notify_error(e); NULL })
        if (!is.null(chb)) {
          history_b(c(history_b(), list(list(role = "user", content = text))))
          shiny::withProgress(message = "Thinking (second backend)", value = 0.5, {
            reply_b <- tryCatch(chb$say(text), error = function(e) { notify_error(e); NULL })
          })
          if (is.null(reply_b)) {
            hb <- history_b()
            history_b(hb[seq_len(length(hb) - 1)])
          } else {
            history_b(chb$history())
            chat_obj_b(chb)
          }
        }
      }
    })

    shiny::observeEvent(input$new, {
      history(list())
      chat_obj(NULL)
      context_info(NULL)
      sources_by_index(list())
      history_b(list())
      chat_obj_b(NULL)
    })

    shiny::observeEvent(input$load, {
      f <- input$load
      if (is.null(f)) return()
      rec <- tryCatch(read_json(f$datapath), error = function(e) NULL)
      if (is.null(rec) || !identical(rec$format, "dragonfarm-chat")) {
        shiny::showNotification("That file is not a dragonfarm chat transcript.", type = "warning")
        return()
      }
      msgs <- rec$messages %||% list()
      history(msgs)
      chat_obj(NULL)
      context_info(NULL)
      if (!is.null(rec$system)) shiny::updateTextAreaInput(session, "system", value = rec$system)
      if (!is.null(rec$settings$temperature)) shiny::updateNumericInput(session, "temperature", value = rec$settings$temperature)
      if (!is.null(rec$settings$max_new_tokens)) shiny::updateNumericInput(session, "max_new_tokens", value = rec$settings$max_new_tokens)
      if (!is.null(rec$settings$context_window)) shiny::updateNumericInput(session, "context_window", value = rec$settings$context_window)
      shiny::showNotification(sprintf("Loaded %d message%s from %s.", length(msgs), if (length(msgs) != 1) "s" else "", f$name), type = "message")
    })

    # Per-reply verdicts shown as badges; the record itself goes to
    # feedback.jsonl. Feedback and editing apply to the primary
    # conversation; the second, comparison thread is read-only.
    verdicts <- shiny::reactiveVal(list())

    fb_button <- function(label, action, i, title) {
      shiny::tags$button(
        type = "button", class = "btn btn-sm btn-outline-secondary fb-btn", title = title,
        onclick = sprintf("Shiny.setInputValue('%s', {action: '%s', i: %d, nonce: Math.random()}, {priority: 'event'})", ns("fb"), action, i),
        label
      )
    }

    render_bubbles <- function(h, editable, v = list(), sources = list()) {
      if (!length(h)) return(shiny::p(class = "hint", "Nothing yet. Say something below."))
      shiny::tagList(lapply(seq_along(h), function(i) {
        m <- h[[i]]
        controls <- NULL
        footnotes <- if (m$role == "assistant") sources_footnotes(sources[[as.character(i)]])
        if (editable && m$role == "assistant") {
          badge <- v[[as.character(i)]]
          controls <- shiny::div(class = "fb-row",
            fb_button("\U0001F44D", "up", i, "Good reply"),
            fb_button("\U0001F44E", "down", i, "Bad reply"),
            fb_button("Edit", "edit", i, "Replace with a better reply"),
            if (i == length(h)) fb_button("Regenerate", "regen", i, "Ask again"),
            if (!is.null(badge)) shiny::span(class = paste("fb-badge", badge), switch(badge, up = "liked", down = "disliked", edited = "edited"))
          )
        }
        shiny::div(class = paste("bubble", m$role),
          shiny::span(class = "role", if (m$role == "assistant") "model" else "you"),
          if (m$role == "assistant") shiny::div(class = "content md", md_html(m$content)) else shiny::div(class = "content", m$content),
          footnotes,
          controls
        )
      }))
    }
    output$thread <- shiny::renderUI(render_bubbles(history(), editable = TRUE, v = verdicts(), sources = sources_by_index()))
    output$thread_b <- shiny::renderUI(render_bubbles(history_b(), editable = FALSE))

    output$panes <- shiny::renderUI({
      primary <- bslib::card(bslib::card_header(shiny::uiOutput(ns("title"), inline = TRUE)),
                             shiny::div(class = "chat-thread", shiny::uiOutput(ns("thread")),
                               shiny::div(id = ns("streaming_bubble"), class = "bubble assistant", style = "display:none;",
                                 shiny::span(class = "role", "model"),
                                 shiny::div(id = ns("streaming_content"), class = "content"))))
      if (!isTRUE(input$compare)) return(primary)
      bslib::layout_columns(col_widths = c(6, 6), primary,
        bslib::card(bslib::card_header(shiny::uiOutput(ns("title_b"), inline = TRUE)),
                   shiny::div(class = "chat-thread", shiny::uiOutput(ns("thread_b")))))
    })
    shiny::outputOptions(output, "panes", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "context_banner", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "title", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "title_b", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "thread", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "thread_b", suspendWhenHidden = FALSE)

    label_now <- function() {
      b <- backend()
      if (!is.null(b) && is_server_backend(b)) b$model else input$run %||% "run"
    }

    shiny::observeEvent(input$fb, {
      ev <- input$fb
      h <- history()
      i <- as.integer(ev$i)
      if (is.na(i) || i > length(h) || !identical(h[[i]]$role, "assistant")) return()
      sys <- if (nzchar(trimws(input$system %||% ""))) input$system
      context <- h[seq_len(i - 1)]
      switch(ev$action,
        up = , down = {
          record_feedback(runs_dir, label_now(), sys, context, h[[i]]$content, rating = if (ev$action == "up") 1 else -1, source = "app")
          v <- verdicts(); v[[as.character(i)]] <- ev$action; verdicts(v)
          shiny::showNotification("Thanks, recorded. dragon_feedback() turns these into training data.", type = "message", duration = 4)
        },
        edit = {
          shiny::showModal(shiny::modalDialog(
            title = "Replace the model's reply",
            shiny::textAreaInput(ns("edit_text"), NULL, value = h[[i]]$content, rows = 8, width = "100%"),
            footer = shiny::tagList(shiny::modalButton("Cancel"), shiny::actionButton(ns("edit_save"), "Save as the better reply", class = "btn-primary")),
            size = "l", easyClose = TRUE
          ))
          session$userData$edit_index <- i
        },
        regen = {
          ch <- tryCatch(build_chat(), error = function(e) { notify_error(e); NULL })
          if (is.null(ch)) return()
          stream_msg(reset = TRUE)
          shiny::withProgress(message = "Asking again", value = 0.5, {
            ok <- tryCatch({ ch$regenerate(on_token = function(piece) stream_msg(text = piece)); TRUE },
                          error = function(e) { notify_error(e); FALSE })
          })
          stream_msg(hide = TRUE)
          if (ok) {
            history(ch$history())
            chat_obj(ch)
            context_info(ch$context_usage())
            v <- verdicts(); v[[as.character(i)]] <- NULL; verdicts(v)
          }
        }
      )
    })

    shiny::observeEvent(input$edit_save, {
      i <- session$userData$edit_index
      h <- history()
      text <- trimws(input$edit_text %||% "")
      if (is.null(i) || !nzchar(text) || i > length(h)) { shiny::removeModal(); return() }
      sys <- if (nzchar(trimws(input$system %||% ""))) input$system
      record_feedback(runs_dir, label_now(), sys, h[seq_len(i - 1)], h[[i]]$content, edited = text, source = "app")
      h[[i]]$content <- text
      history(h)
      v <- verdicts(); v[[as.character(i)]] <- "edited"; verdicts(v)
      shiny::removeModal()
      shiny::showNotification("Saved. The edited reply is now part of this conversation and of the feedback data.", type = "message", duration = 5)
    })

    output$save <- shiny::downloadHandler(
      filename = function() sprintf("dragonfarm-chat-%s.json", format(Sys.time(), "%Y%m%d-%H%M%S")),
      content = function(file) {
        ch <- chat_obj()
        if (is.null(ch)) {
          write_json(list(format = "dragonfarm-chat", version = 1L, saved_at = now_iso(), messages = history()), file)
        } else {
          ch$save(file)
        }
      },
      contentType = "application/json"
    )

    export_example_content <- function(file) {
      h <- history()
      shiny::req(length(h) > 0)
      sys <- if (nzchar(trimws(input$system %||% ""))) input$system
      msgs <- if (!is.null(sys)) c(list(list(role = "system", content = sys)), h) else h
      write_conversations(list(msgs), file)
    }
    output$export_example <- shiny::downloadHandler(
      filename = function() sprintf("dragonfarm-example-%s.jsonl", format(Sys.time(), "%Y%m%d-%H%M%S")),
      content = export_example_content,
      contentType = "application/jsonl"
    )
  })
}
