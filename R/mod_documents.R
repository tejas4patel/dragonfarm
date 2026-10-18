# Documents panel: the default way in. Drop files or pages, read and index
# them into a document set, ask questions with cited sources, then carry
# the set into Chat. A table of prompt/response rows is the other route,
# reached from the link at the bottom of the Documents card.

DOCUMENT_EXTENSIONS <- c(".pdf", ".html", ".htm", ".md", ".markdown", ".txt", ".docx", ".xlsx", ".xlsm", ".csv", ".tsv")

mod_documents_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    mod_documents_top_ui(ns),
    bslib::card(
      bslib::card_header("Teach: practice questions from these documents"),
      shiny::p(class = "hint", "A model writes questions each chunk can answer, filters mark the weak ones, and you review before anything trains. Expect to keep roughly half; the review is the point."),
      bslib::layout_columns(
        col_widths = c(4, 2, 3, 3),
        shiny::selectInput(ns("generator"), label_with_info("Written by", "questions"), choices = c("Recommended local model" = ""), width = "100%"),
        shiny::numericInput(ns("per_chunk"), "Per chunk", value = 3, min = 1, max = 6, step = 1),
        shiny::checkboxInput(ns("include_quotes"), "Include quoted passages", value = FALSE),
        shiny::checkboxInput(ns("mix"), "Mix question types (what, why/how, how they differ)", value = TRUE),
        shiny::selectInput(ns("qset"), "Or review an earlier set", choices = c("Choose" = ""), width = "100%")
      ),
      shiny::div(class = "cloud-actions",
        shiny::actionButton(ns("generate"), "Write practice questions", class = "btn-primary"),
        shiny::uiOutput(ns("gen_status"), inline = TRUE)
      ),
      shiny::uiOutput(ns("review"))
    )
  )
}

mod_documents_top_ui <- function(ns) {
  bslib::layout_columns(
    col_widths = c(5, 7),
    bslib::card(
      bslib::card_header("Documents"),
      shiny::div(class = "dropzone",
        shiny::fileInput(ns("files"), label = NULL, multiple = TRUE, buttonLabel = "Browse",
                         placeholder = "Drop PDF, Word, HTML, Markdown, text, or spreadsheet files here",
                         accept = DOCUMENT_EXTENSIONS, width = "100%")
      ),
      bslib::layout_columns(
        col_widths = c(8, 4),
        shiny::textInput(ns("url"), label = shiny::tags$span(class = "visually-hidden", "Web page address"), placeholder = "https://... a web page", width = "100%"),
        shiny::actionButton(ns("add_url"), "Add page", class = "btn-outline-secondary", width = "100%")
      ),
      shiny::uiOutput(ns("pending")),
      shiny::textInput(ns("name"), "Name this set", value = "my-documents", width = "100%"),
      shiny::div(class = "cloud-actions",
        shiny::actionButton(ns("build"), "Read and index", class = "btn-primary"),
        shiny::actionButton(ns("example"), "Load the example policies", class = "btn-outline-primary")
      ),
      shiny::p(class = "hint", "Files are copied into the set's folder under the runs directory, so the set survives this session. Reading the same set again picks up only what changed."),
      shiny::hr(),
      shiny::selectInput(ns("saved"), "Or open a saved set", choices = c("Choose a set" = ""), width = "100%"),
      shiny::uiOutput(ns("summary")),
      shiny::p(class = "hint mt-3", shiny::actionLink(ns("table_route"), "Have a table of prompts and replies instead?"))
    ),
    bslib::card(
      bslib::card_header("Ask"),
      shiny::textAreaInput(ns("question"), label = shiny::tags$span(class = "visually-hidden", "Your question"), rows = 3, width = "100%",
                           placeholder = "Ask anything the documents should be able to answer."),
      bslib::layout_columns(
        col_widths = c(8, 4),
        shiny::selectInput(ns("model"), label_with_info("Answered by", "answer"), choices = c("Recommended for this machine" = ""), width = "100%"),
        shiny::numericInput(ns("k"), "Excerpts", value = 4, min = 1, max = 12, step = 1)
      ),
      shiny::checkboxInput(ns("compare"), "Look for documents that disagree", value = FALSE),
      shiny::div(class = "cloud-actions",
        shiny::actionButton(ns("ask"), "Ask", class = "btn-primary"),
        shiny::actionButton(ns("to_chat"), "Continue in Chat", class = "btn-outline-secondary")
      ),
      shiny::p(class = "hint", "It reads the most relevant parts of your documents and answers in full; the sources are listed underneath if you want to check. Nothing is trained yet."),
      shiny::uiOutput(ns("answer")),
      # While an answer is being written it streams into this bubble (the
      # click handler blocks, so these messages bypass Shiny's reactive
      # flush); the finished, formatted answer then replaces it.
      shiny::div(id = ns("streaming_bubble"), class = "bubble assistant", style = "display:none;",
                 shiny::span(class = "role", "writing"), shiny::div(id = ns("streaming_content"), class = "content")),
      shiny::tags$script(shiny::HTML(sprintf(
        "Shiny.addCustomMessageHandler('%s', function(msg) {
           var bubble = document.getElementById('%s'), content = document.getElementById('%s'), answer = document.getElementById('%s');
           if (!bubble || !content) return;
           if (msg.reset) { content.textContent = ''; if (answer) answer.style.display = 'none'; }
           if (msg.text) content.textContent += msg.text;
           bubble.style.display = msg.hide ? 'none' : 'block';
           if (msg.hide && answer) answer.style.display = '';
         });",
        ns("stream"), ns("streaming_bubble"), ns("streaming_content"), ns("answer")
      )))
    )
  )
}

mod_documents_server <- function(id, state, nav_to, runs_dir) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns
    pending_files <- shiny::reactiveVal(data.frame(name = character(), datapath = character(), stringsAsFactors = FALSE))
    pending_urls <- shiny::reactiveVal(character())
    answer <- shiny::reactiveVal(NULL)

    shiny::observeEvent(input$files, {
      f <- input$files
      keep <- tolower(paste0(".", tools::file_ext(f$name))) %in% DOCUMENT_EXTENSIONS
      if (any(!keep)) shiny::showNotification(sprintf("Skipped %s: not a supported document type.", paste(f$name[!keep], collapse = ", ")), type = "warning")
      cur <- pending_files()
      add <- f[keep, c("name", "datapath"), drop = FALSE]
      cur <- rbind(cur[!cur$name %in% add$name, , drop = FALSE], add)
      pending_files(cur)
    })

    shiny::observeEvent(input$add_url, {
      u <- trimws(input$url %||% "")
      if (!nzchar(u)) return()
      if (!grepl("^https?://", u, ignore.case = TRUE)) u <- paste0("https://", u)
      pending_urls(unique(c(pending_urls(), u)))
      shiny::updateTextInput(session, "url", value = "")
    })

    output$pending <- shiny::renderUI({
      files <- pending_files(); urls <- pending_urls()
      if (!nrow(files) && !length(urls)) return(NULL)
      shiny::div(class = "pending-list",
        if (nrow(files)) shiny::tags$ul(lapply(files$name, shiny::tags$li)),
        if (length(urls)) shiny::tags$ul(lapply(urls, function(u) shiny::tags$li(shiny::code(u))))
      )
    })

    saved_sets <- shiny::reactivePoll(4000, session,
      checkFunc = function() runs_change_signature(file.path(runs_dir, "documents")),
      valueFunc = function() tryCatch(dragon_documents_list(runs_dir), error = function(e) NULL)
    )
    shiny::observe({
      sets <- saved_sets()
      choices <- c("Choose a set" = "")
      if (!is.null(sets) && nrow(sets)) choices <- c(choices, stats::setNames(sets$dir, sprintf("%s (%d chunks)", sets$name, sets$chunks)))
      current <- shiny::isolate(state$documents)
      shiny::updateSelectInput(session, "saved", choices = choices,
                               selected = if (!is.null(current) && current$dir %in% choices) current$dir else "")
    })
    shiny::observeEvent(input$saved, {
      d <- input$saved
      if (is.null(d) || !nzchar(d)) return()
      cur <- state$documents
      if (!is.null(cur) && identical(cur$dir, d)) return()
      docs <- tryCatch(dragon_documents_load(d), error = function(e) { notify_error(e); NULL })
      if (!is.null(docs)) { state$documents <- docs; answer(NULL); warm_up(docs) }
    })

    # Warm up what the first question would otherwise pay for in silence: the
    # inference worker, the embedding model (via the index check), and the
    # hardware check that picks the default answer model. The answer model
    # itself still loads on the first question.
    warm_up <- function(docs) {
      shiny::withProgress(message = "Preparing retrieval for this set (first time loads a small embedding model).", value = 0.5, {
        tryCatch({
          if (is.null(state$hardware)) state$hardware <- hardware_info()
          worker_start()
          dragon_index(docs)
        }, error = function(e) notify_error(e))
      })
    }

    # Read and index: uploads are copied into <set>/uploads so their paths
    # outlive the session's temp files, then dragon_documents() does the rest.
    shiny::observeEvent(input$build, {
      files <- pending_files(); urls <- pending_urls()
      name <- slugify(input$name %||% "")
      if (!nrow(files) && !length(urls)) {
        # A large file takes a while to upload (about 10 s for 3 MB); until the bar
        # says "Upload complete" the server has not seen it.
        shiny::showNotification("Add at least one file or page first. If a file is still uploading, wait for \"Upload complete\" under the drop box.", type = "warning", duration = 8)
        return()
      }
      upload_dir <- file.path(runs_dir, "documents", name, "uploads")
      dir.create(upload_dir, recursive = TRUE, showWarnings = FALSE)
      if (nrow(files)) file.copy(files$datapath, file.path(upload_dir, files$name), overwrite = TRUE)
      paths <- c(if (dir.exists(upload_dir) && length(list.files(upload_dir))) upload_dir, urls)
      shiny::withProgress(message = "Reading and indexing. The first time downloads a small embedding model.", value = 0.4, {
        docs <- tryCatch(dragon_documents(paths, name = name, runs_dir = runs_dir), error = function(e) { notify_error(e); NULL })
      })
      if (is.null(docs)) return()
      state$documents <- docs
      answer(NULL)
      if (is.null(state$hardware)) state$hardware <- tryCatch(hardware_info(), error = function(e) NULL)
      pending_files(pending_files()[0, , drop = FALSE])
      pending_urls(character())
      shiny::showNotification(sprintf("%s: %d chunks eaten. Ask away.", docs$name, docs$manifest$n_chunks), type = "message", duration = 5)
    })

    shiny::observeEvent(input$example, {
      shiny::withProgress(message = "Reading and indexing the example policies.", value = 0.4, {
        docs <- tryCatch(dragon_documents(dragon_example_documents(), name = "example-policies", runs_dir = runs_dir),
                         error = function(e) { notify_error(e); NULL })
      })
      if (is.null(docs)) return()
      state$documents <- docs
      answer(NULL)
      if (is.null(state$hardware)) state$hardware <- tryCatch(hardware_info(), error = function(e) NULL)
      shiny::updateTextAreaInput(session, "question", value = "How long is the return window?")
    })

    output$summary <- shiny::renderUI({
      docs <- state$documents
      if (is.null(docs)) return(shiny::p(class = "hint", "The dragon is hungry. Drop files above, or open a saved set."))
      m <- docs$manifest
      shiny::tagList(
        shiny::div(class = "kv", shiny::span("Set"), shiny::strong(docs$name)),
        shiny::tags$ul(class = "source-list", lapply(m$sources, function(s) {
          flags <- c(if (isTRUE(s$changelog_like)) "changelog, down-weighted", if (!is.null(s$error)) paste("could not read:", s$error))
          shiny::tags$li(s$name, sprintf(" \u2014 %d chunks", as.integer(s$n_chunks)),
                         if (length(flags)) shiny::span(class = "text-muted small", paste0(" (", paste(flags, collapse = "; "), ")")))
        })),
        shiny::div(class = "kv", shiny::span("Index"), shiny::strong(if (is.null(m$index)) "not built yet" else m$index$model)),
        shiny::div(class = "btn-row",
          shiny::actionButton(session$ns("verify"), "Check it re-reads the same", class = "btn-outline-secondary btn-sm"),
          shiny::uiOutput(session$ns("verify_result"), inline = TRUE)),
        shiny::div(class = "btn-row",
          shiny::actionButton(session$ns("pii"), "Check for personal data", class = "btn-outline-secondary btn-sm")),
        shiny::uiOutput(session$ns("pii_result"))
      )
    })

    # Personal data: fixed patterns, every hit listed for a person to judge.
    pii <- shiny::reactiveVal(NULL)
    shiny::observeEvent(input$pii, {
      docs <- state$documents
      if (is.null(docs)) return()
      h <- tryCatch(pii_scan(docs, runs_dir = runs_dir), error = function(e) { notify_error(e); NULL })
      if (!is.null(h)) pii(list(set = docs$name, hits = h))
    })
    output$pii_result <- shiny::renderUI({
      p <- pii()
      docs <- state$documents
      if (is.null(p) || is.null(docs) || !identical(p$set, docs$name)) return(NULL)
      h <- p$hits
      if (!nrow(h)) return(shiny::p(class = "small text-success", "No email addresses, phone numbers, ID numbers, card numbers, dates of birth or record ids found."))
      counts <- attr(h, "counts"); counts <- counts[counts > 0]
      labels <- c(email = "email addresses", phone = "phone numbers", ssn = "social security numbers", card = "card numbers",
                  birth_date = "dates of birth", record_id = "patient or record ids")
      shiny::tagList(
        shiny::p(class = "small text-warning", paste0("Found ", paste(sprintf("%d %s", counts, labels[names(counts)]), collapse = ", "),
                 ". Check each: contact lines of organisations are common in public documents.")),
        shiny::div(class = "table-wrap", shiny::tags$table(class = "table table-sm",
          shiny::tags$thead(shiny::tags$tr(lapply(c("Type", "Found", "Where", "Context"), shiny::tags$th))),
          shiny::tags$tbody(lapply(seq_len(nrow(h)), function(i) shiny::tags$tr(
            shiny::tags$td(labels[[h$type[i]]]), shiny::tags$td(h$match[i]), shiny::tags$td(h$source[i]),
            shiny::tags$td(class = "small", h$context[i]))))))
      )
    })

    # Read the set's files again and compare, without touching the set.
    verified <- shiny::reactiveVal(NULL)
    shiny::observeEvent(input$verify, {
      docs <- state$documents
      if (is.null(docs)) return()
      v <- shiny::withProgress(message = "Reading the files again...", value = 0.5,
                               tryCatch(documents_verify(docs, runs_dir = runs_dir), error = function(e) list(verdict = "error", error = conditionMessage(e))))
      verified(c(v, list(set = docs$name)))
    })
    output$verify_result <- shiny::renderUI({
      v <- verified()
      docs <- state$documents
      if (is.null(v) || is.null(docs) || !identical(v$set, docs$name)) return(NULL)
      msg <- switch(v$verdict,
        identical = sprintf("Identical: all %d files re-read byte for byte.", v$files),
        "sources changed" = paste0("Some files changed or are missing", if (length(v$missing)) paste0(" (missing: ", paste(basename(v$missing), collapse = ", "), ")") else "", ". Read the set again to update it."),
        "reader changed" = "This version of dragonfarm reads the files differently. Read the set again to update it.",
        differs = "The chunks differ although the files and reader are the same. Please report this.",
        "nothing to check" = "None of the files can be found on this computer.",
        error = paste("Could not check:", v$error),
        v$verdict)
      extra <- if (length(v$not_checked)) sprintf(" Web pages are not fetched again (%d).", length(v$not_checked)) else ""
      shiny::span(class = paste("small", if (identical(v$verdict, "identical")) "text-success" else "text-warning"), paste0(msg, extra))
    })

    runs <- shiny::reactivePoll(4000, session,
      checkFunc = function() runs_change_signature(runs_dir),
      valueFunc = function() {
        df <- dragon_runs(runs_dir)
        df[file.exists(file.path(df$dir, "adapter", "adapter_config.json")), , drop = FALSE]
      }
    )
    shiny::observe({
      df <- runs()
      hw <- state$hardware
      rec <- if (!is.null(hw$tier)) sprintf("Recommended for this machine (%s)", hw$tier$model) else "Recommended for this machine"
      choices <- stats::setNames("", rec)
      if (nrow(df)) choices <- c(choices, stats::setNames(paste0("run:", df$id), paste("Run", df$id)))
      choices <- c(choices, stats::setNames(dragon_presets()$id, dragon_presets()$id))
      shiny::updateSelectInput(session, "model", choices = choices, selected = shiny::isolate(input$model) %||% "")
    })
    chosen_model <- function() {
      m <- input$model
      if (is.null(m) || !nzchar(m)) return(NULL)
      if (startsWith(m, "run:")) dragon_run(file.path(runs_dir, sub("^run:", "", m))) else m
    }

    # Pieces of an answer pushed straight to the browser as they are written;
    # never allowed to break asking (a test session may not support it).
    stream_msg <- function(...) tryCatch(session$sendCustomMessage(session$ns("stream"), list(...)), error = function(e) NULL)

    shiny::observeEvent(input$ask, {
      q <- trimws(input$question %||% "")
      if (!nzchar(q)) { shiny::showNotification("Type a question first.", type = "warning"); return() }
      docs <- state$documents
      if (is.null(docs)) { shiny::showNotification("Read some documents first, or open a saved set.", type = "warning"); return() }
      stream_msg(reset = TRUE)
      shiny::withProgress(message = "The dragon is reading", value = 0.1, {
        ans <- tryCatch(
          dragon_ask(docs, q, model = chosen_model(), k = input$k %||% 4, compare = isTRUE(input$compare),
                     on_stage = function(msg) shiny::incProgress(0.3, detail = msg),
                     on_token = function(piece) stream_msg(text = piece)),
          error = function(e) { notify_error(e); NULL })
      })
      if (!is.null(ans)) answer(ans)
      stream_msg(hide = TRUE)
    })

    output$answer <- shiny::renderUI({
      a <- answer()
      if (is.null(a)) return(NULL)
      shiny::tagList(
        shiny::div(class = "bubble user", shiny::span(class = "role", "you"), shiny::div(class = "content", a$question)),
        shiny::div(class = "bubble assistant", shiny::span(class = "role", a$model), shiny::div(class = "content md", md_html(a$answer)), sources_footnotes(a$sources),
                   check_note(a), trace_note(a$trace))
      )
    })

    shiny::observeEvent(input$to_chat, {
      if (is.null(state$documents)) { shiny::showNotification("Read some documents first.", type = "warning"); return() }
      nav_to("chat")
    })
    shiny::observeEvent(input$table_route, {
      state$route <- "table"
      nav_to("data")
    })

    # Teach: generate in the background, poll the progress file, then review. ----
    job <- shiny::reactiveVal(NULL)
    questions <- shiny::reactiveVal(NULL)   # the dragon_questions data frame under review

    shiny::observe({
      state$hardware
      choices <- c("Recommended local model" = "")
      if (nzchar(Sys.getenv("ANTHROPIC_API_KEY"))) choices <- c(choices, "Claude API (ANTHROPIC_API_KEY)" = "anthropic")
      p <- dragon_presets()
      choices <- c(choices, stats::setNames(p$id, ifelse(p$load_in_4bit, paste(p$id, "(4-bit)"), p$id)))
      shiny::updateSelectInput(session, "generator", choices = choices, selected = shiny::isolate(input$generator) %||% "")
    })
    shiny::observe({
      docs <- state$documents
      choices <- c("Choose" = "")
      if (!is.null(docs)) {
        lst <- tryCatch(dragon_questions_list(docs), error = function(e) NULL)
        if (!is.null(lst) && nrow(lst)) {
          choices <- c(choices, stats::setNames(lst$file, sprintf("%s: %d pairs, %s kept (%s)", lst$stamp, lst$pairs,
                                                                  ifelse(is.na(lst$kept), "?", lst$kept), ifelse(is.na(lst$generator), "?", lst$generator))))
        }
      }
      shiny::updateSelectInput(session, "qset", choices = choices, selected = "")
    })
    shiny::observeEvent(input$qset, {
      p <- input$qset
      if (is.null(p) || !nzchar(p)) return()
      qa <- tryCatch(dragon_questions_load(p), error = function(e) { notify_error(e); NULL })
      if (!is.null(qa)) questions(qa)
    })

    shiny::observeEvent(input$generate, {
      docs <- state$documents
      if (is.null(docs)) { shiny::showNotification("Read some documents first.", type = "warning"); return() }
      if (!is.null(job()) && isTRUE(dragon_questions_progress(job())$alive)) {
        shiny::showNotification("Questions are already being written.", type = "warning"); return()
      }
      gen <- input$generator %||% ""
      n <- as.integer(input$per_chunk %||% 3)
      if (identical(gen, "anthropic")) {
        shiny::withProgress(message = "Asking the Claude API for questions on each chunk.", value = 0.4, {
          qa <- tryCatch(dragon_questions(docs, generator = dragon_llm_anthropic(), n_per_chunk = n,
                                          mix = !identical(input$mix, FALSE),
                                          include_quotes = isTRUE(input$include_quotes)),
                         error = function(e) { notify_error(e); NULL })
        })
        if (!is.null(qa)) questions(qa)
        return()
      }
      j <- tryCatch(dragon_questions(docs, generator = if (nzchar(gen)) gen else NULL, n_per_chunk = n,
                                     mix = !identical(input$mix, FALSE),
                                     include_quotes = isTRUE(input$include_quotes), wait = FALSE),
                    error = function(e) { notify_error(e); NULL })
      if (!is.null(j)) { job(j); questions(NULL) }
    })

    progress <- shiny::reactive({
      j <- job()
      if (is.null(j)) return(NULL)
      p <- dragon_questions_progress(j)
      if (!p$state %in% c("done", "failed")) shiny::invalidateLater(2000, session)
      p
    })
    shiny::observeEvent(progress(), {
      p <- progress()
      if (is.null(p) || !identical(p$state, "done")) return()
      qa <- tryCatch(dragon_questions_load(job()$out), error = function(e) { notify_error(e); NULL })
      if (!is.null(qa)) questions(qa)
      job(NULL)
    }, ignoreNULL = TRUE)

    output$gen_status <- shiny::renderUI({
      p <- progress()
      if (is.null(p)) return(NULL)
      if (identical(p$state, "failed")) {
        return(shiny::span(class = "text-danger small", "Generation failed. ", shiny::code(basename(job()$log)), " has the details."))
      }
      if (identical(p$state, "loading") || is.na(p$total)) return(shiny::span(class = "hint", "Loading the model..."))
      shiny::span(class = "hint", sprintf("%d of %d chunks done: %d pairs so far, %d kept by the filters.", p$done, p$total, p$pairs, p$kept))
    })

    # Review: pairs grouped by chunk; a checkbox per pair, rejected ones
    # unticked with their reason. Decisions are saved back to the file.
    output$review <- shiny::renderUI({
      qa <- questions()
      if (is.null(qa)) return(NULL)
      if (!nrow(qa)) return(shiny::p(class = "hint", "The model wrote nothing usable. Try a larger generator."))
      groups <- split(seq_len(nrow(qa)), factor(qa$chunk_id, levels = unique(qa$chunk_id)))
      # PDF pages, as answers show them: looked up from the set's chunks.
      pages <- tryCatch({
        ch <- dragon_chunks(attr(qa, "documents"))
        ch$page[match(qa$chunk_id, ch$id)]
      }, error = function(e) rep(NA_integer_, nrow(qa)))
      blocks <- lapply(groups, function(idx) {
        where <- source_label(qa$source[idx[1]], qa$section[idx[1]], pages[idx[1]])
        names_html <- lapply(idx, function(i) {
          shiny::div(class = paste("qa", if (!qa$keep[i]) "rejected"),
            shiny::div(class = "q", qa$question[i]),
            shiny::div(class = "a", qa$answer[i]),
            if (!is.na(qa$reason[i])) shiny::span(class = "why", qa$reason[i])
          )
        })
        shiny::tags$details(open = NA, class = "qa-chunk",
          shiny::tags$summary(shiny::strong(where), sprintf(" (%d of %d kept)", sum(qa$keep[idx]), length(idx))),
          # width = "100%": Shiny's default input width is 300px, which squeezed
          # every question and answer into a narrow column.
          shiny::checkboxGroupInput(ns(paste0("keep_", qa$chunk_id[idx[1]])), label = NULL, width = "100%",
                                    choiceNames = names_html, choiceValues = qa$id[idx], selected = qa$id[idx][qa$keep[idx]])
        )
      })
      shiny::tagList(
        shiny::div(class = "kv mt-3", shiny::span("Review"),
          shiny::strong(sprintf("%d of %d kept", sum(qa$keep), nrow(qa))),
          if (!is.null(attr(qa, "meta")$generator)) shiny::span(class = "text-muted small", paste0("  written by ", attr(qa, "meta")$generator))),
        shiny::div(class = "cloud-actions",
          shiny::actionButton(ns("save_review"), "Save decisions", class = "btn-outline-primary"),
          shiny::actionButton(ns("to_model"), "Continue to Model", class = "btn-primary"),
          shiny::span(class = "hint", "Continue builds the training set from the ticked pairs, with retrieved excerpts in every prompt, and skips the Data and Map steps.")
        ),
        blocks
      )
    })

    reviewed <- function() {
      qa <- questions()
      if (is.null(qa)) return(NULL)
      for (cid in unique(qa$chunk_id)) {
        sel <- input[[paste0("keep_", cid)]]
        if (is.null(sel)) sel <- character()   # all unticked
        qa$keep[qa$chunk_id == cid] <- qa$id[qa$chunk_id == cid] %in% sel
      }
      qa
    }
    shiny::observeEvent(input$save_review, {
      qa <- reviewed()
      if (is.null(qa)) return()
      qa <- tryCatch(dragon_questions_save(qa), error = function(e) { notify_error(e); NULL })
      if (!is.null(qa)) { questions(qa); shiny::showNotification(sprintf("Saved: %d of %d kept.", sum(qa$keep), nrow(qa)), type = "message") }
    })
    shiny::observeEvent(input$to_model, {
      qa <- reviewed()
      if (is.null(qa)) return()
      if (!any(qa$keep)) { shiny::showNotification("Tick at least a few pairs first.", type = "warning"); return() }
      qa <- tryCatch(dragon_questions_save(qa), error = function(e) { notify_error(e); NULL })
      if (is.null(qa)) return()
      shiny::withProgress(message = "Retrieving excerpts for every kept question.", value = 0.5, {
        ds <- tryCatch(dragon_questions_dataset(qa, state$documents), error = function(e) { notify_error(e); NULL })
      })
      if (is.null(ds)) return()
      state$dataset <- ds
      state$mapped <- ds
      shiny::showNotification(training_rows_message(ds$data), type = "message")
      nav_to("model")
    })
  })
}

# "40 training rows ready (34 questions and 6 'not covered' examples)."
training_rows_message <- function(d) {
  n_neg <- if (is.null(d$negative)) 0L else sum(d$negative)
  detail <- if (n_neg > 0) sprintf(" (%d questions and %d 'not covered' example%s)", nrow(d) - n_neg, n_neg, if (n_neg == 1) "" else "s") else ""
  sprintf("%d training rows ready%s. Pick a model next.", nrow(d), detail)
}
