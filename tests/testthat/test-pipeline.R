test_that("step constructors validate their inputs", {
  ds <- dragon_map(dragon_dataset(toy_df()), "subject", "reply")
  pairs <- dragon_map_pairs(dragon_dataset(data.frame(q = "a", g = "b", b = "c")), "q", "g", "b")
  expect_s3_class(dragon_step_train(ds), "dragon_step")
  expect_error(dragon_step_train(pairs), "dragon_map")
  expect_equal(dragon_step_prefer()$method, "dpo")
  expect_error(dragon_step_prefer(ds), "dragon_map_pairs")
  expect_error(dragon_step_synthesize_pairs(), "judge")
  expect_equal(dragon_step_synthesize_pairs(judge = function(p) p, n = 10)$n, 10)
  expect_error(dragon_step_judge(), "judge")
  expect_equal(dragon_step_evaluate("exact")$metrics, "exact")
  expect_error(dragon_step_evaluate("nope"), "Unknown")
  prompts <- dragon_map_prompts(dragon_dataset(data.frame(q = "a")), "q")
  rl <- dragon_step_reinforce(prompts, rewards = dragon_reward("json"))
  expect_equal(rl$rewards[[1]]$type, "json")
  expect_error(dragon_step_reinforce(ds, rewards = dragon_reward("json")), "dragon_map_prompts")
  expect_error(dragonfarm:::check_steps(list("train")), "dragon_step")
  expect_length(dragonfarm:::check_steps(dragon_step_evaluate()), 1)
  msgs <- testthat::capture_messages(print(dragon_step_evaluate()))
  expect_true(any(grepl("evaluate", msgs)))
})

test_that("a pipeline runs steps in order, records progress, and compares its runs", {
  runs <- tempfile("runs-")
  dir.create(runs)
  parent_dir <- file.path(runs, "20260913-101500-smollm2")
  dir.create(parent_dir)
  file.copy(list.files(fixture_path("run1"), full.names = TRUE), parent_dir, recursive = TRUE)
  run <- fixture_with_samples(parent_dir)

  p <- suppressMessages(dragon_pipeline(run, list(dragon_step_evaluate(metrics = c("exact", "token_f1"))), runs_dir = runs, name = "eval only"))
  expect_s3_class(p, "dragon_pipeline")
  expect_equal(p$status, "succeeded")
  expect_match(p$id, "-eval-only$")
  expect_equal(p$steps[[1]]$state, "succeeded")
  expect_named(p$results[[1]]$metrics, c("exact", "token_f1"))
  expect_true(file.exists(p$path))
  rec <- dragon_pipeline_status(p$id, runs_dir = runs)
  expect_equal(rec$status, "succeeded")
  expect_equal(rec$steps[[1]]$type, "evaluate")
  msgs <- testthat::capture_messages(print(rec))
  expect_true(any(grepl("succeeded", msgs)))
  expect_true(any(grepl("evaluate", testthat::capture_messages(print(p)))))
  expect_equal(dragon_status(run)$metrics$exact, p$results[[1]]$metrics$exact)
})

test_that("a failing step is recorded and the error propagates", {
  runs <- tempfile("runs-")
  err <- tryCatch(
    suppressMessages(dragon_pipeline("HuggingFaceTB/SmolLM2-135M-Instruct", list(dragon_step_prefer()), runs_dir = runs)),
    error = function(e) e
  )
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err), "failed at step 1")
  recs <- list.files(file.path(runs, "pipelines"), pattern = "\\.json$", full.names = TRUE)
  expect_length(recs, 1)
  rec <- dragonfarm:::read_json(recs[1])
  expect_equal(rec$status, "failed")
  expect_equal(rec$steps[[1]]$state, "failed")
  expect_match(rec$steps[[1]]$error, "no pairs")
  expect_error(dragon_pipeline_status("nope", runs_dir = runs), "No pipeline record")
  expect_error(dragon_pipeline("x/y", list()), "dragon_step")
})

test_that("background pipelines serialize their spec and build a loader script", {
  run <- fixture_with_samples()
  spec <- dragonfarm:::strip_handles(list(model = run, steps = list(dragon_step_evaluate())))
  expect_null(spec$model$process)
  expect_s3_class(spec$model, "dragon_run")
  script <- dragonfarm:::pipeline_script(tempfile(fileext = ".rds"))
  expect_match(script, "run_pipeline_file", fixed = TRUE)
  expect_match(script, "dragonfarm", fixed = TRUE)
})

test_that("a background pipeline runs from a script file, not Rscript -e", {
  run <- fixture_with_samples()
  runs <- tempfile("runs-")
  dir.create(runs)
  launched <- NULL
  testthat::local_mocked_bindings(launch_rscript = function(script_path, log_path) {
    launched <<- list(script = script_path, log = log_path)
    structure(list(), class = "fake_process")
  })
  p <- suppressMessages(dragon_pipeline(run, list(dragon_step_evaluate()), runs_dir = runs, background = TRUE))
  expect_true(file.exists(launched$script))
  expect_match(launched$script, paste0(p$id, ".R"), fixed = TRUE)
  expect_match(paste(readLines(launched$script), collapse = "\n"), "run_pipeline_file", fixed = TRUE)
  expect_equal(launched$log, p$log)
})

test_that("lineage ordering nests children under parents", {
  o <- dragonfarm:::lineage_order(c("a", "b", "c", "d"), c(NA, "a", "b", NA))
  expect_equal(o$id, c("a", "b", "c", "d"))
  expect_equal(o$depth, c(0L, 1L, 2L, 0L))
  o2 <- dragonfarm:::lineage_order(c("x", "y"), c("gone", "x"))
  expect_equal(o2$id, c("x", "y"))
  expect_equal(o2$depth, c(0L, 1L))
})

test_that("the pipeline module refuses to start without inputs and lists records", {
  runs <- tempfile("runs-")
  dir.create(file.path(runs, "pipelines"), recursive = TRUE)
  dragonfarm:::write_json(list(id = "p1", status = "succeeded", steps = list(list(type = "train", state = "succeeded", run = "r1"))),
                          file.path(runs, "pipelines", "p1.json"))
  state <- shiny::reactiveValues(dataset = NULL, mapped = NULL, model = NULL, run = NULL)
  shiny::testServer(dragonfarm:::mod_pipeline_server, args = list(state = state, runs_dir = runs), {
    session$setInputs(judge_kind = "local", judge_model = "org/m", pair_prompts = 10, judge_n = 4)
    expect_length(problems(), 2)
    state$mapped <- dragon_map(dragon_dataset(toy_df()), "subject", "reply")
    state$model <- list(id = "x/y")
    expect_length(problems(), 0)
    recs <- records()
    expect_length(recs, 1)
    expect_equal(recs[[1]]$id, "p1")
  })
})

test_that("a merge step is a step, and pipeline summaries mention merged output", {
  expect_s3_class(dragon_step_merge(), "dragon_step")
  expect_equal(dragon_step_merge("out/dir")$out, "out/dir")
  expect_error(dragon_step_merge(42), "out")
  rec <- structure(list(id = "p", status = "succeeded",
                        steps = list(list(type = "merge", state = "succeeded", summary = list(merged = "D:/m")))),
                   class = "dragon_pipeline_status")
  expect_true(any(grepl("D:/m", testthat::capture_messages(print(rec)))))
})

test_that("a cancel request stops a pipeline between steps", {
  runs <- tempfile("runs-")
  dir.create(runs)
  run <- fixture_with_samples()
  rec_path <- file.path(dragonfarm:::pipelines_dir(runs), "p-cancel.json")
  record <- list(id = "p-cancel", status = "queued", runs_dir = runs,
                 steps = list(list(type = "evaluate", state = "queued"), list(type = "evaluate", state = "queued")))
  dragonfarm:::write_json(record, rec_path)
  writeLines("now", dragonfarm:::cancel_path(rec_path))
  out <- suppressMessages(dragonfarm:::run_pipeline(run, list(dragon_step_evaluate(), dragon_step_evaluate()), runs, record, rec_path))
  expect_equal(out$status, "cancelled")
  expect_equal(vapply(out$steps, `[[`, "", "state"), c("skipped", "skipped"))
  st <- dragon_pipeline_status("p-cancel", runs_dir = runs)
  expect_equal(st$status, "cancelled")
  expect_true(any(grepl("cancelled", testthat::capture_messages(print(st)))))
  # cancelling again is a no-op
  again <- suppressMessages(dragon_pipeline_cancel("p-cancel", runs_dir = runs))
  expect_equal(again$status, "cancelled")
})

test_that("dragon_pipeline_cancel marks the record, asks running runs to stop, and kills a stuck runner", {
  runs <- tempfile("runs-")
  dir.create(runs)
  # a run this pipeline started that is still training
  run_dir <- file.path(runs, "20260916-120000-child")
  dir.create(run_dir)
  dragonfarm:::write_json(list(created_at = "2026-09-16T12:00:00Z", stage = "sft", model = list(id = "x/y")), file.path(run_dir, "config.json"))
  dragonfarm:::write_json(list(state = "running"), file.path(run_dir, "status.json"))
  # an older run that is not part of it
  old_dir <- file.path(runs, "20260901-000000-old")
  dir.create(old_dir)
  dragonfarm:::write_json(list(created_at = "2026-09-01T00:00:00Z", stage = "sft", model = list(id = "x/y")), file.path(old_dir, "config.json"))
  dragonfarm:::write_json(list(state = "running"), file.path(old_dir, "status.json"))

  # A script file and a private temp folder: a killed `Rscript -e` leaves an
  # "Rscript*" file in the temp folder, which R CMD check reports as detritus.
  sleep_tmp <- tempfile("sleeper-")
  dir.create(sleep_tmp)
  sleep_script <- file.path(sleep_tmp, "sleep.R")
  writeLines("Sys.sleep(120)", sleep_script)
  sleeper <- processx::process$new(file.path(R.home("bin"), "Rscript"), sleep_script, windows_hide_window = TRUE,
                                   env = c("current", TMPDIR = sleep_tmp, TMP = sleep_tmp, TEMP = sleep_tmp))
  withr::defer({ if (sleeper$is_alive()) sleeper$kill(); unlink(sleep_tmp, recursive = TRUE) })
  rec_path <- file.path(dragonfarm:::pipelines_dir(runs), "p-live.json")
  dragonfarm:::write_json(list(id = "p-live", status = "running", runs_dir = runs, started_at = "2026-09-16T11:59:00Z",
                               pid = sleeper$get_pid(),
                               steps = list(list(type = "train", state = "running"), list(type = "judge", state = "queued"))),
                          rec_path)

  st <- suppressMessages(dragon_pipeline_cancel("p-live", runs_dir = runs, wait = FALSE))
  expect_equal(st$status, "running")
  expect_true(file.exists(dragonfarm:::cancel_path(rec_path)))
  expect_true(file.exists(file.path(run_dir, "cancel.request")))
  expect_false(file.exists(file.path(old_dir, "cancel.request")))

  st <- suppressMessages(dragon_pipeline_cancel("p-live", runs_dir = runs, wait = TRUE, timeout = 0))
  expect_equal(st$status, "cancelled")
  expect_equal(vapply(st$steps, `[[`, "", "state"), c("cancelled", "skipped"))
  Sys.sleep(0.5)
  expect_false(sleeper$is_alive())
  # once the process is gone, a stale "running" record reads as failed
  dragonfarm:::write_json(list(id = "p-dead", status = "running", pid = sleeper$get_pid(), steps = list()),
                          file.path(dragonfarm:::pipelines_dir(runs), "p-dead.json"))
  expect_equal(dragon_pipeline_status("p-dead", runs_dir = runs)$status, "failed")
})

test_that("the pipeline module's cancel button writes a cancel request", {
  root <- tempfile("runs-")
  dir.create(file.path(root, "pipelines"), recursive = TRUE)
  dragonfarm:::write_json(list(id = "p1", status = "running", runs_dir = root, pid = Sys.getpid(),
                               steps = list(list(type = "train", state = "running"))),
                          file.path(root, "pipelines", "p1.json"))
  state <- shiny::reactiveValues(dataset = NULL, mapped = NULL, model = NULL, run = NULL)
  shiny::testServer(dragonfarm:::mod_pipeline_server, args = list(state = state, runs_dir = root), {
    html <- as.character(output$pipelines$html)
    expect_match(html, "Cancel")
    session$setInputs(cancel = list(id = "p1", nonce = 1))
    expect_true(file.exists(file.path(root, "pipelines", "p1.cancel")))
  })
})

test_that("app task helpers summarise records and read judgements back", {
  rec <- list(status = "failed", steps = list(list(type = "judge", state = "failed", error = "boom")))
  expect_equal(dragonfarm:::task_error(rec), "boom")
  expect_equal(dragonfarm:::task_error(list(status = "failed", steps = list())), "no details were recorded")
  expect_null(dragonfarm:::task_status_ui(NULL, "x"))
  running <- as.character(dragonfarm:::task_status_ui(list(id = "p9", state = "running"), "The judge"))
  expect_match(running, "p9")
  failed <- as.character(dragonfarm:::task_status_ui(list(id = "p9", state = "failed", error = "boom"), "The judge"))
  expect_match(failed, "boom")
  expect_null(dragonfarm:::task_status_ui(list(id = "p9", state = "succeeded"), "x"))

  run <- fixture_with_samples()
  expect_null(dragonfarm:::last_judgement(run))
  dragonfarm:::write_json(list(
    list(mode = "score", summary = list(mean_score = 6, n = 1), details = list(list(prompt = "a", reply = "b", score = 6))),
    list(mode = "pairwise", against = "base", summary = list(win_rate = 0.5, n = 2),
         details = list(list(prompt = "p1", a = "x", b = "y", verdict = "a"), list(prompt = "p2", a = "x", b = "y", verdict = NULL)))
  ), file.path(run$dir, "judge.json"))
  j <- dragonfarm:::last_judgement(run)
  expect_equal(j$mode, "pairwise")
  expect_equal(nrow(j$details), 2)
  expect_equal(j$details$verdict, c("a", "unparsed"))
  expect_equal(j$summary$win_rate, 0.5)
})

test_that("a publish step validates its repo and dispatches to dragon_publish", {
  expect_s3_class(dragon_step_publish("user/name"), "dragon_step")
  expect_equal(dragon_step_publish("user/name")$what, "merged")
  expect_equal(dragon_step_publish("user/name", what = "adapter")$what, "adapter")
  expect_error(dragon_step_publish(42), "repo")

  run <- fixture_with_samples()
  runs_dir <- tempfile("runs-")
  dir.create(runs_dir)
  seen <- list()
  testthat::local_mocked_bindings(
    dragon_publish = function(run, repo, what = "merged", private = FALSE, commit_message = NULL) {
      seen[["repo"]] <<- repo
      seen[["what"]] <<- what
      seen[["private"]] <<- private
      "https://huggingface.co/user/name"
    }
  )
  step <- dragon_step_publish("user/name", private = TRUE)
  p <- suppressMessages(dragon_pipeline(run, list(step), runs_dir = runs_dir, name = "publish only"))
  expect_equal(p$status, "succeeded")
  expect_equal(p$results[[1]]$url, "https://huggingface.co/user/name")
  expect_equal(seen$repo, "user/name")
  expect_true(seen$private)
  expect_true(any(grepl("huggingface.co", testthat::capture_messages(print(dragon_pipeline_status(p))))))
})

test_that("synthesized pairs reload from their file", {
  dir <- tempfile("synth-")
  dir.create(dir)
  file <- file.path(dir, "pairs.jsonl")
  df <- data.frame(prompt = c("q1", "q2"), chosen = c("good", "great"), rejected = c("bad", "worse"),
                   chosen_score = c(8, 9), rejected_score = c(3, 2), system = "Be brief.", stringsAsFactors = FALSE)
  dragonfarm:::write_synth(df, file, list(kind = "pairs"))
  ds <- dragonfarm:::load_synth_pairs(file)
  expect_equal(dragonfarm:::mapping_kind(ds), "pairs")
  expect_equal(nrow(ds$data), 2)
  expect_equal(ds$mapping$system, "{`system`}")
  expect_equal(attr(ds, "synthesis")$kind, "pairs")
})

test_that("dragon_compare() takes a background pipeline (its runs, not its runs_dir)", {
  runs <- withr::local_tempdir()
  mk <- function(id) {
    d <- file.path(runs, id); dir.create(d)
    jsonlite::write_json(list(model = list(id = "m"), stage = "sft"), file.path(d, "config.json"), auto_unbox = TRUE)
    jsonlite::write_json(list(state = "succeeded", eval_loss = 1.5), file.path(d, "status.json"), auto_unbox = TRUE)
  }
  mk("run-a"); mk("run-b")
  dir.create(file.path(runs, "pipelines"))
  path <- file.path(runs, "pipelines", "p1.json")
  jsonlite::write_json(list(id = "p1", status = "succeeded", runs_dir = runs,
                            steps = list(list(type = "train", state = "succeeded", run = "run-a"),
                                         list(type = "prefer", state = "succeeded", run = "run-b"))),
                       path, auto_unbox = TRUE)
  # What dragon_pipeline(background = TRUE) returns: runs_dir and no runs.
  p <- structure(list(id = "p1", path = path, log = "", process = NULL, runs_dir = runs), class = "dragon_pipeline")
  cmp <- dragon_compare(p)
  expect_equal(cmp$id, c("run-a", "run-b"))
  expect_match(paste(cli::cli_fmt(print(p)), collapse = " "), "0 runs")   # not the length of runs_dir
})
