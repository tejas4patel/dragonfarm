tryit_runs_dir <- function() {
  dir <- copy_fixture_run()
  dirname(dir)
}

test_that("Generate warns on an empty prompt and otherwise fills in the tuned and base replies", {
  runs_dir <- tryit_runs_dir()
  run_id <- basename(list.dirs(runs_dir, recursive = FALSE)[1])
  testthat::local_mocked_bindings(
    dragon_generate = function(x, prompt, system = NULL, max_new_tokens = 256, temperature = 0.7, base = FALSE, backend = dragon_backend()) {
      if (isTRUE(base)) paste("base reply to", prompt) else paste("tuned reply to", prompt)
    }
  )
  state <- shiny::reactiveValues()
  shiny::testServer(dragonfarm:::mod_tryit_server, args = list(state = state, runs_dir = runs_dir), {
    session$setInputs(run = run_id, prompt = "", compare = TRUE, go = 1)
    tuned_html <- as.character(output$tuned$html)
    expect_match(tuned_html, "Nothing generated yet.", fixed = TRUE)

    session$setInputs(prompt = "How do I reset it?", go = 2)
    expect_equal(replies$tuned, "tuned reply to How do I reset it?")
    expect_equal(replies$base, "base reply to How do I reset it?")
    tuned_html <- as.character(output$tuned$html)
    expect_match(tuned_html, "tuned reply to How do I reset it?", fixed = TRUE)

    session$setInputs(compare = FALSE)
    base_html <- as.character(output$base$html)
    expect_match(base_html, "Comparison is off.", fixed = TRUE)
  })
})

test_that("a failed generation is reported instead of crashing the module", {
  runs_dir <- tryit_runs_dir()
  run_id <- basename(list.dirs(runs_dir, recursive = FALSE)[1])
  testthat::local_mocked_bindings(dragon_generate = function(...) stop("worker is down"))
  state <- shiny::reactiveValues()
  shiny::testServer(dragonfarm:::mod_tryit_server, args = list(state = state, runs_dir = runs_dir), {
    session$setInputs(run = run_id, prompt = "hi", compare = FALSE, go = 1)
    expect_equal(replies$tuned, "(failed)")
  })
})

test_that("Judge and Improve refuse to start without an API key or a local model name", {
  runs_dir <- tryit_runs_dir()
  run_id <- basename(list.dirs(runs_dir, recursive = FALSE)[1])
  withr::local_envvar(ANTHROPIC_API_KEY = NA)
  state <- shiny::reactiveValues()
  shiny::testServer(dragonfarm:::mod_tryit_server, args = list(state = state, runs_dir = runs_dir), {
    session$setInputs(run = run_id, judge_kind = "anthropic", judge = 1)
    expect_null(judgement())
    session$setInputs(judge_kind = "local", judge_model = "  ", judge = 2)
    expect_null(judgement())

    session$setInputs(synth_split = "train", synth = 1)
    expect_null(synth_result())
  })
})

test_that("Merge, Publish, and Judge run as background tasks and report their results", {
  runs_dir <- tryit_runs_dir()
  run_id <- basename(list.dirs(runs_dir, recursive = FALSE)[1])
  fake_handle <- list(id = "fake-task")
  testthat::local_mocked_bindings(
    app_task_start = function(run, step, runs_dir, name) fake_handle,
    app_task_watch = function(handle, on_done, ...) on_done(list(
      status = "succeeded",
      steps = list(list(summary = list(merged = "path/to/merged", url = "https://huggingface.co/x/y", file = "pairs.jsonl")))
    )),
    last_judgement = function(run) list(mode = "score", summary = list(mean_score = 8.5, n = 3), details = data.frame(prompt = "p", score = 8, stringsAsFactors = FALSE)),
    hf_token_present = function() TRUE,
    load_synth_pairs = function(file) {
      ds <- dragon_map_pairs(dragon_dataset(data.frame(q = "p1", g = "good", b = "bad", stringsAsFactors = FALSE)), "q", "g", "b")
      ds$data$chosen_score <- 9
      ds$data$rejected_score <- 2
      ds
    },
    dragon_prompts = function(run, split = "eval", n = Inf, seed = 42) c("p1", "p2", "p3")
  )
  state <- shiny::reactiveValues(dataset = NULL, mapped = NULL)
  shiny::testServer(dragonfarm:::mod_tryit_server, args = list(state = state, runs_dir = runs_dir), {
    session$setInputs(run = run_id)

    session$setInputs(merge_dir = "", merge = 1)
    expect_equal(merged(), "path/to/merged")
    expect_match(as.character(output$merge_result$html), "path/to/merged", fixed = TRUE)

    session$setInputs(publish_repo = "yourname/demo", publish = 1)
    expect_equal(published(), "https://huggingface.co/x/y")
    expect_match(as.character(output$publish_result$html), "https://huggingface.co/x/y", fixed = TRUE)

    session$setInputs(judge_kind = "local", judge_model = "org/model", judge = 1)
    expect_equal(judgement()$summary$mean_score, 8.5)
    expect_match(as.character(output$judge_out$html), "Mean score 8.50", fixed = TRUE)

    session$setInputs(judge_kind = "local", judge_model = "org/model", synth = 1)
    expect_equal(synth_result()$n, 1)
    expect_identical(state$dataset, state$mapped)
  })
})

test_that("Publish refuses without a repo name or an HF token", {
  runs_dir <- tryit_runs_dir()
  run_id <- basename(list.dirs(runs_dir, recursive = FALSE)[1])
  testthat::local_mocked_bindings(hf_token_present = function() FALSE)
  state <- shiny::reactiveValues()
  shiny::testServer(dragonfarm:::mod_tryit_server, args = list(state = state, runs_dir = runs_dir), {
    session$setInputs(run = run_id, publish_repo = "", publish = 1)
    expect_null(published())
    session$setInputs(publish_repo = "yourname/demo", publish = 2)
    expect_null(published())
  })
})


test_that("Judge can use a free tier once it has a key and an opt-in", {
  runs_dir <- tryit_runs_dir()
  run_id <- basename(list.dirs(runs_dir, recursive = FALSE)[1])
  withr::local_envvar(OPENROUTER_API_KEY = NA)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  started <- NULL
  testthat::local_mocked_bindings(app_task_start = function(run, step, runs_dir, name) { started <<- step; list(id = "t1") },
                                  app_task_watch = function(...) NULL)
  state <- shiny::reactiveValues()
  shiny::testServer(dragonfarm:::mod_tryit_server, args = list(state = state, runs_dir = runs_dir), {
    session$setInputs(run = run_id, judge_kind = "provider", judge_provider = "openrouter",
                      judge_model = "meta-llama/llama-3.3-70b-instruct:free", against = "base", judge_n = 5, rubric = "")
    session$setInputs(judge = 1)
    expect_null(started)                                                  # no key yet
    withr::local_envvar(OPENROUTER_API_KEY = "sk-or-test")
    session$setInputs(judge = 2)
    expect_null(started)                                                  # not opted in yet
    dragonfarm:::provider_opt_in("openrouter", runs_dir = runs_dir)
    session$setInputs(judge = 3)
    expect_false(is.null(started))
    expect_equal(attr(started$judge, "label"), "openrouter:meta-llama/llama-3.3-70b-instruct:free")
  })
})
