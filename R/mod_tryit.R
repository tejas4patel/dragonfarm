mod_tryit_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_columns(
      col_widths = c(5, 7),
      bslib::card(
        bslib::card_header("Ask the model"),
        shiny::selectInput(ns("run"), label_with_info("Run", "train"), choices = character(), width = "100%"),
        shiny::textInput(ns("system"), "System prompt (optional)", width = "100%"),
        shiny::textAreaInput(ns("prompt"), "Prompt", rows = 5, width = "100%",
                             placeholder = "My Ember thermostat keeps dropping off Wi-Fi."),
        bslib::layout_columns(
          col_widths = c(6, 6),
          shiny::numericInput(ns("max_new_tokens"), "Max new tokens", value = 600, min = 1, step = 10),
          shiny::numericInput(ns("temperature"), "Temperature", value = 0.3, min = 0, max = 2, step = 0.1)
        ),
        shiny::checkboxInput(ns("compare"), "Also show the base model's reply", value = TRUE),
        shiny::selectInput(ns("documents"), "Answer from documents", choices = c("No, just the prompt" = ""), width = "100%"),
        shiny::actionButton(ns("go"), "Generate", class = "btn-primary"),
        shiny::p(class = "text-muted small mt-2", "The local worker keeps the model loaded between requests, so only the first one is slow.")
      ),
      bslib::layout_columns(
        col_widths = c(6, 6),
        bslib::card(bslib::card_header("Fine-tuned"), shiny::uiOutput(ns("tuned"))),
        bslib::card(bslib::card_header("Base model"), shiny::uiOutput(ns("base")))
      )
    ),
    bslib::card(
      bslib::card_header("Judge"),
      shiny::p(class = "hint", "Ask a stronger model to compare this run's replies with another model's on the held-out prompts. Each pair is judged twice with the order swapped, so a judge that favours the first answer cannot tip the result."),
      bslib::layout_columns(
        col_widths = c(4, 4, 2, 2),
        shiny::selectInput(ns("judge_kind"), "Judge", choices = c("Claude API (ANTHROPIC_API_KEY)" = "anthropic", "Local model" = "local", "A free tier (OpenRouter, Groq)" = "provider")),
        shiny::uiOutput(ns("judge_model_ui")),
        shiny::selectInput(ns("against"), "Compare with", choices = c("What it started from" = "base", "Nothing: score 1-10" = "none")),
        shiny::numericInput(ns("judge_n"), "Prompts", value = 10, min = 1, max = 200, step = 1)
      ),
      shiny::textInput(ns("rubric"), "Rubric (optional)", width = "100%",
                       placeholder = "Reward replies that give concrete next steps and stay under 120 words."),
      shiny::actionButton(ns("judge"), "Run judge", class = "btn-outline-primary"),
      shiny::uiOutput(ns("judge_out"))
    ),
    bslib::card(
      bslib::card_header("Improve: preference pairs from this run's own replies"),
      shiny::p(class = "hint", "Closes the loop. The run answers each prompt several times, the judge above scores every sample, and the best and worst become chosen and rejected pairs. The pairs load into the Map step, ready for a DPO or ORPO stage that starts from this run."),
      bslib::layout_columns(
        col_widths = c(3, 3, 3, 3),
        shiny::selectInput(ns("synth_split"), "Prompts from", choices = c("Training rows" = "train", "Held-out rows" = "eval")),
        shiny::numericInput(ns("synth_n"), "Prompts", value = 50, min = 2, max = 2000, step = 10),
        shiny::numericInput(ns("synth_samples"), "Samples per prompt", value = 4, min = 2, max = 8, step = 1),
        shiny::numericInput(ns("synth_gap"), "Min score gap", value = 2, min = 0, max = 9, step = 0.5)
      ),
      shiny::actionButton(ns("synth"), "Build preference pairs", class = "btn-outline-primary"),
      shiny::uiOutput(ns("synth_out"))
    ),
    bslib::card(
      bslib::card_header("Export"),
      bslib::layout_columns(
        col_widths = c(8, 4),
        shiny::textInput(ns("merge_dir"), "Merged model directory", placeholder = "leave blank for <run>/merged", width = "100%"),
        shiny::actionButton(ns("merge"), "Merge and save", class = "btn-outline-primary", style = "margin-top: 32px")
      ),
      shiny::uiOutput(ns("merge_result"))
    ),
    bslib::card(
      bslib::card_header("Publish to the Hugging Face Hub"),
      shiny::p(class = "hint", "Push this run's model to a repo on the Hub, ready for a hosted Inference Endpoint or any tool that loads a model by repo id. Creates the repo if it does not exist. Needs a Hugging Face token with write access, added in Settings."),
      bslib::layout_columns(
        col_widths = c(6, 3, 3),
        shiny::textInput(ns("publish_repo"), "Repo", placeholder = "yourname/support-agent-0.5b", width = "100%"),
        shiny::selectInput(ns("publish_what"), "Format", choices = c("Merged model (plain transformers)" = "merged", "Adapter only (small, needs peft)" = "adapter")),
        shiny::checkboxInput(ns("publish_private"), "Private repo", value = FALSE)
      ),
      shiny::actionButton(ns("publish"), "Publish", class = "btn-outline-primary"),
      shiny::uiOutput(ns("publish_result"))
    )
  )
}

mod_tryit_server <- function(id, state, runs_dir) {
  shiny::moduleServer(id, function(input, output, session) {
    runs <- shiny::reactivePoll(3000, session,
      checkFunc = function() runs_change_signature(runs_dir),
      valueFunc = function() runs_with_adapter(runs_dir)
    )
    shiny::observe({
      df <- runs()
      selected <- shiny::isolate(input$run)
      if (!is.null(state$run) && state$run$id %in% df$id && (is.null(selected) || !nzchar(selected))) selected <- state$run$id
      labels <- if (nrow(df)) sprintf("%s  [%s]", df$id, df$state) else character()
      shiny::updateSelectInput(session, "run", choices = stats::setNames(df$id, labels),
                               selected = if (!is.null(selected) && selected %in% df$id) selected else df$id[1])
    })

    run <- shiny::reactive({
      shiny::req(input$run)
      run_open(input$run, runs_dir)
    })

    replies <- shiny::reactiveValues(tuned = NULL, base = NULL)

    shiny::observeEvent(input$go, {
      prompt <- trimws(input$prompt %||% "")
      if (!nzchar(prompt)) {
        shiny::showNotification("Type a prompt first.", type = "warning")
        return()
      }
      r <- run()
      sys <- if (nzchar(trimws(input$system %||% ""))) input$system
      docs <- if (!is.null(input$documents) && nzchar(input$documents)) {
        tryCatch(dragon_documents_load(input$documents), error = function(e) { notify_error(e); NULL })
      }
      replies$tuned <- NULL
      replies$base <- NULL
      # With a document set chosen, both replies come from dragon_ask(): the
      # same retrieved excerpts, with sources shown under each reply.
      one <- function(base) {
        if (is.null(docs)) {
          dragon_generate(r, prompt, system = sys, max_new_tokens = input$max_new_tokens, temperature = input$temperature, base = base)
        } else {
          dragon_ask(docs, prompt, model = r, system = sys, max_new_tokens = input$max_new_tokens,
                     temperature = input$temperature, base = base)
        }
      }
      shiny::withProgress(message = "Generating with the fine-tuned model", value = 0.3, {
        replies$tuned <- tryCatch(one(FALSE), error = function(e) { notify_error(e); "(failed)" })
        if (isTRUE(input$compare)) {
          shiny::incProgress(0.4, message = "Generating with the base model")
          replies$base <- tryCatch(one(TRUE), error = function(e) { notify_error(e); "(failed)" })
        }
      })
    })

    reply_ui <- function(x) {
      if (is.null(x)) return(shiny::p(class = "hint", "Nothing generated yet."))
      if (inherits(x, "dragon_answer")) {
        return(shiny::div(class = "bubble assistant", shiny::div(class = "content md", md_html(x$answer)), sources_footnotes(x$sources)))
      }
      shiny::div(class = "bubble assistant", shiny::div(class = "content md", md_html(x)))
    }

    shiny::observe({
      runs()   # re-list when anything under runs_dir changes
      sets <- tryCatch(dragon_documents_list(runs_dir), error = function(e) NULL)
      choices <- c("No, just the prompt" = "")
      if (!is.null(sets) && nrow(sets)) choices <- c(choices, stats::setNames(sets$dir, sprintf("%s (%d chunks)", sets$name, sets$chunks)))
      open <- state$documents
      selected <- if (!is.null(open) && open$dir %in% choices) open$dir else shiny::isolate(input$documents) %||% ""
      shiny::updateSelectInput(session, "documents", choices = choices, selected = selected)
    })
    output$tuned <- shiny::renderUI(reply_ui(replies$tuned))
    output$base <- shiny::renderUI({
      if (!isTRUE(input$compare)) return(shiny::p(class = "hint", "Comparison is off."))
      reply_ui(replies$base)
    })

    output$judge_model_ui <- shiny::renderUI({
      if (identical(input$judge_kind, "local")) {
        shiny::textInput(session$ns("judge_model"), "Model id or directory", value = "Qwen/Qwen2.5-1.5B-Instruct")
      } else if (identical(input$judge_kind, "provider")) {
        shiny::tagList(
          shiny::selectInput(session$ns("judge_provider"), "Provider", choices = c("OpenRouter" = "openrouter", "Groq" = "groq")),
          shiny::uiOutput(session$ns("judge_provider_model"))
        )
      } else {
        shiny::selectInput(session$ns("judge_model"), "Model",
                           choices = c("claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"))
      }
    })

    # The provider's current models, so nobody has to guess an id that no
    # longer exists; any id can still be typed.
    output$judge_provider_model <- shiny::renderUI({
      shiny::req(input$judge_provider)
      ids <- provider_models(input$judge_provider, runs_dir = runs_dir)
      if (!length(ids)) return(shiny::textInput(session$ns("judge_model"), "Model id", placeholder = "a model id from the provider's site"))
      shiny::selectizeInput(session$ns("judge_model"), "Model", choices = ids, selected = ids[1],
                            options = list(create = TRUE))
    })

    # The judge picked in the Judge card, or NULL after saying what is missing.
    # Claude and the free tiers need a key from Settings; a free tier also
    # needs the opt-in there. Nothing is sent from here: the judge runs in
    # the background and checks again before every request.
    chosen_judge <- function() {
      kind <- input$judge_kind %||% "anthropic"
      model <- trimws(input$judge_model %||% "")
      warn <- function(msg) { shiny::showNotification(msg, type = "warning", duration = 10); NULL }
      if (identical(kind, "local")) return(if (nzchar(model)) model else warn("Name a local model to judge with."))
      if (identical(kind, "provider")) {
        name <- input$judge_provider %||% "openrouter"
        p <- provider_info(name)
        if (!nzchar(model)) return(warn(sprintf("Name a %s model to judge with.", p$title)))
        if (!nzchar(Sys.getenv(p$key_env))) return(warn(sprintf("Add your %s key in Settings first.", p$title)))
        if (!isTRUE(provider_status(name, runs_dir)$opted_in)) return(warn(sprintf("Turn on %s under Free tiers in Settings first.", p$title)))
        return(llm_provider(name, model, system = judge_system_prompt(), runs_dir = runs_dir))
      }
      if (!nzchar(Sys.getenv("ANTHROPIC_API_KEY"))) return(warn("Add your Claude API key in Settings to use Claude as the judge, or pick another judge."))
      dragon_judge_anthropic(model = if (nzchar(model)) model else "claude-opus-5")
    }

    judgement <- shiny::reactiveVal(NULL)
    shiny::observeEvent(input$judge, {
      r <- run()
      judge <- chosen_judge()
      if (is.null(judge)) return()
      rubric <- if (nzchar(trimws(input$rubric %||% ""))) input$rubric
      against <- if (identical(input$against, "none")) NULL else "base"
      h <- tryCatch(
        app_task_start(r, dragon_step_judge(against = against, judge = judge, n = input$judge_n %||% 10, rubric = rubric), runs_dir, "judge"),
        error = function(e) { notify_error(e); NULL }
      )
      if (is.null(h)) return()
      judgement(NULL)
      judge_task(list(id = h$id, state = "running"))
      app_task_watch(h, function(rec) {
        judge_task(list(id = h$id, state = rec$status, error = task_error(rec)))
        if (identical(rec$status, "succeeded")) judgement(last_judgement(r))
      })
    })

    judge_task <- shiny::reactiveVal(NULL)
    output$judge_out <- shiny::renderUI({
      j <- judgement()
      if (is.null(j)) return(task_status_ui(judge_task(), "The judge"))
      s <- j$summary
      headline <- if (identical(j$mode, "pairwise")) {
        sprintf("Wins %.0f%% \u00b7 ties %.0f%% \u00b7 losses %.0f%% over %d prompts (position-consistent %.0f%%)",
                100 * s$win_rate, 100 * s$tie_rate, 100 * s$loss_rate, s$n, 100 * s$position_consistency)
      } else {
        sprintf("Mean score %.2f / 10 over %d prompts", s$mean_score, s$n)
      }
      d <- j$details
      rows <- lapply(seq_len(min(nrow(d), 5)), function(i) {
        if (identical(j$mode, "pairwise")) {
          shiny::div(class = "judge-row",
            shiny::div(class = "judge-prompt", d$prompt[i]),
            shiny::div(class = paste("judge-verdict", d$verdict[i]),
                       switch(d$verdict[i], a = "this run", b = j$against, tie = "tie", "unparsed")))
        } else {
          shiny::div(class = "judge-row",
            shiny::div(class = "judge-prompt", d$prompt[i]),
            shiny::div(class = "judge-verdict", sprintf("%s / 10", d$score[i])))
        }
      })
      shiny::tagList(
        shiny::p(class = "text-success small", headline),
        if (isTRUE(s$unparsed > 0)) shiny::p(class = "text-warning small", sprintf("%d judge replies could not be parsed.", s$unparsed)),
        rows,
        shiny::p(class = "hint", "Saved to judge.json in the run; the Monitor panel's comparison table shows it.")
      )
    })

    synth_result <- shiny::reactiveVal(NULL)
    shiny::observeEvent(input$synth, {
      r <- run()
      judge <- chosen_judge()
      if (is.null(judge)) return()
      prompts <- dragon_prompts(r, input$synth_split %||% "train", n = input$synth_n %||% 50)
      if (length(prompts) < 2) {
        shiny::showNotification("This run has too few prompts in that split.", type = "warning")
        return()
      }
      rubric <- if (nzchar(trimws(input$rubric %||% ""))) input$rubric
      step <- dragon_step_synthesize_pairs(prompts = input$synth_split %||% "train", n = input$synth_n %||% 50, judge = judge,
                                           n_samples_per_prompt = input$synth_samples %||% 4, min_gap = input$synth_gap %||% 2,
                                           rubric = rubric)
      h <- tryCatch(app_task_start(r, step, runs_dir, "improve"), error = function(e) { notify_error(e); NULL })
      if (is.null(h)) return()
      synth_result(NULL)
      synth_task(list(id = h$id, state = "running"))
      app_task_watch(h, function(rec) {
        synth_task(list(id = h$id, state = rec$status, error = task_error(rec)))
        if (!identical(rec$status, "succeeded")) return()
        ds <- load_synth_pairs(rec$steps[[1]]$summary$file)
        state$dataset <- ds
        state$mapped <- ds
        synth_result(list(n = nrow(ds$data), file = ds$source, run = r$id,
                          chosen = mean(ds$data$chosen_score), rejected = mean(ds$data$rejected_score)))
        shiny::showNotification(sprintf("%d pairs loaded. Go to Train, pick %s under Start from, and run DPO.", nrow(ds$data), r$id),
                                type = "message", duration = 12)
      })
    })

    synth_task <- shiny::reactiveVal(NULL)
    output$synth_out <- shiny::renderUI({
      s <- synth_result()
      if (is.null(s)) return(task_status_ui(synth_task(), "Pair building"))
      shiny::tagList(
        shiny::p(class = "text-success small",
                 sprintf("%d pairs built from %s (mean judge score: chosen %.1f, rejected %.1f).", s$n, s$run, s$chosen, s$rejected)),
        shiny::p(class = "hint", "Saved to ", shiny::code(s$file), " and loaded as the current dataset. In Train, choose this run under Start from; the stage switches to preference optimization automatically.")
      )
    })

    merged <- shiny::reactiveVal(NULL)
    shiny::observeEvent(input$merge, {
      r <- run()
      out <- if (nzchar(trimws(input$merge_dir %||% ""))) input$merge_dir else NULL
      h <- tryCatch(app_task_start(r, dragon_step_merge(out), runs_dir, "merge"), error = function(e) { notify_error(e); NULL })
      if (is.null(h)) return()
      merged(NULL)
      merge_task(list(id = h$id, state = "running"))
      app_task_watch(h, function(rec) {
        merge_task(list(id = h$id, state = rec$status, error = task_error(rec)))
        if (identical(rec$status, "succeeded")) merged(rec$steps[[1]]$summary$merged)
      })
    })
    merge_task <- shiny::reactiveVal(NULL)
    output$merge_result <- shiny::renderUI({
      m <- merged()
      if (is.null(m)) return(task_status_ui(merge_task(), "The merge"))
      shiny::p(class = "text-success small", "Merged model saved to ", shiny::code(m),
               ". It loads with plain transformers and needs nothing from dragonfarm.")
    })

    published <- shiny::reactiveVal(NULL)
    publish_task <- shiny::reactiveVal(NULL)
    shiny::observeEvent(input$publish, {
      repo <- trimws(input$publish_repo %||% "")
      if (!nzchar(repo)) {
        shiny::showNotification("Name a repo, e.g. yourname/support-agent-0.5b.", type = "warning")
        return()
      }
      if (!hf_token_present()) {
        shiny::showNotification("Add a Hugging Face token with write access in Settings before publishing.", type = "warning", duration = 10)
        return()
      }
      r <- run()
      step <- dragon_step_publish(repo, what = input$publish_what %||% "merged", private = isTRUE(input$publish_private))
      h <- tryCatch(app_task_start(r, step, runs_dir, "publish"), error = function(e) { notify_error(e); NULL })
      if (is.null(h)) return()
      published(NULL)
      publish_task(list(id = h$id, state = "running"))
      app_task_watch(h, function(rec) {
        publish_task(list(id = h$id, state = rec$status, error = task_error(rec)))
        if (identical(rec$status, "succeeded")) published(rec$steps[[1]]$summary$url)
      })
    })
    output$publish_result <- shiny::renderUI({
      u <- published()
      if (is.null(u)) return(task_status_ui(publish_task(), "The publish"))
      shiny::p(class = "text-success small", "Published to ", shiny::tags$a(href = u, target = "_blank", u), ".")
    })
  })
}
