test_that("dragon_runs_dir() defaults under tempdir(), never the working directory", {
  withr::local_envvar(DRAGONFARM_RUNS_DIR = NA)
  withr::local_options(dragonfarm.runs_dir = NULL)
  d <- dragon_runs_dir()
  # d itself doesn't exist yet, and normalizePath() leaves a nonexistent path
  # unresolved, so on macOS (/var -> /private/var) only tempdir() would be
  # resolved. Compare the existing parent directory instead.
  expect_equal(basename(d), "dragonfarm_runs")
  expect_equal(normalizePath(dirname(d), winslash = "/"), normalizePath(tempdir(), winslash = "/"))

  withr::local_options(dragonfarm.runs_dir = "custom/path")
  expect_equal(dragon_runs_dir(), "custom/path")
})

test_that("a finished run can be reopened and inspected", {
  dir <- copy_fixture_run()
  run <- dragon_run(dir)
  expect_s3_class(run, "dragon_run")
  st <- dragon_status(run)
  expect_equal(st$state, "succeeded")
  expect_equal(st$total_steps, 12)
  pr <- dragon_progress(run)
  expect_equal(nrow(pr), 5)
  expect_true(is.na(pr$eval_loss[1]))
  expect_equal(pr$eval_loss[5], 1.644)
  expect_equal(pr$step, c(1, 5, 10, 12, 12))
  expect_length(dragon_logs(run, 2), 2)
  expect_message(print(run), "succeeded")
})

test_that("runs with no progress return an empty frame", {
  dir <- copy_fixture_run()
  unlink(file.path(dir, "progress.jsonl"))
  pr <- dragon_progress(dragon_run(dir))
  expect_equal(nrow(pr), 0)
  expect_true("loss" %in% names(pr))
})

test_that("a dead process is reported as failed", {
  dir <- copy_fixture_run()
  st <- dragonfarm:::read_json(file.path(dir, "status.json"))
  st$state <- "running"
  st$pid <- 2147483000L
  dragonfarm:::write_json(st, file.path(dir, "status.json"))
  out <- dragon_status(dragon_run(dir))
  expect_equal(out$state, "failed")
  expect_match(out$error, "exited without reporting")
})

test_that("dragon_runs lists and orders runs", {
  base <- tempfile("runs-")
  dir.create(base)
  a <- file.path(base, "20260913-101500-smollm2")
  dir.create(a)
  file.copy(list.files(fixture_path("run1"), full.names = TRUE), a, recursive = TRUE)
  dir.create(file.path(base, "not-a-run"))
  df <- dragon_runs(base)
  expect_equal(nrow(df), 1)
  expect_equal(df$state, "succeeded")
  expect_equal(df$model, "HuggingFaceTB/SmolLM2-135M-Instruct")
  expect_equal(nrow(dragon_runs(tempfile())), 0)
})

test_that("not a run directory errors", {
  expect_error(dragon_run(tempfile()), "not a run directory")
})

test_that("archiving hides a run from dragon_runs() and unarchiving restores it", {
  base <- tempfile("runs-")
  dir.create(base)
  dir <- file.path(base, "20260913-101500-smollm2")
  dir.create(dir)
  file.copy(list.files(fixture_path("run1"), full.names = TRUE), dir, recursive = TRUE)
  run <- dragon_run(dir)

  dragon_archive_run(run)
  expect_equal(nrow(dragon_runs(base)), 0)
  archived <- dragon_archived_runs(base)
  expect_equal(archived$id, "20260913-101500-smollm2")
  expect_false(dir.exists(dir))
  expect_true(dir.exists(file.path(base, "archived", "20260913-101500-smollm2")))

  dragon_unarchive_run("20260913-101500-smollm2", runs_dir = base)
  expect_equal(nrow(dragon_runs(base)), 1)
  expect_equal(nrow(dragon_archived_runs(base)), 0)
  expect_true(dir.exists(dir))

  expect_error(dragon_unarchive_run("nope", runs_dir = base), "No archived run")
  dragon_archive_run(run$id, runs_dir = base)
  expect_error(dragon_archive_run(run$id, runs_dir = base), "No run at")   # already archived; nothing left to archive
  dir.create(dir)
  file.copy(list.files(fixture_path("run1"), full.names = TRUE), dir, recursive = TRUE)
  expect_error(dragon_unarchive_run("20260913-101500-smollm2", runs_dir = base), "already exists")
})

test_that("archiving and deleting refuse an active run or one with children, unless forced", {
  base <- tempfile("runs-")
  dir.create(base)
  parent_dir <- file.path(base, "20260913-101500-smollm2")
  dir.create(parent_dir)
  file.copy(list.files(fixture_path("run1"), full.names = TRUE), parent_dir, recursive = TRUE)

  child_dir <- file.path(base, "20260914-000000-child")
  dir.create(child_dir)
  file.copy(list.files(fixture_path("run1"), full.names = TRUE), child_dir, recursive = TRUE)
  cfg <- dragonfarm:::read_json(file.path(child_dir, "config.json"))
  cfg$model$base_run <- "20260913-101500-smollm2"
  dragonfarm:::write_json(cfg, file.path(child_dir, "config.json"))

  expect_error(dragon_archive_run("20260913-101500-smollm2", runs_dir = base), "Other runs continue from")
  expect_error(dragon_delete_run("20260913-101500-smollm2", runs_dir = base), "Other runs continue from")
  dragon_archive_run("20260913-101500-smollm2", runs_dir = base, force = TRUE)
  expect_false(dir.exists(parent_dir))
  expect_true(dir.exists(file.path(base, "archived", "20260913-101500-smollm2")))

  dragonfarm:::write_json(list(state = "running", pid = 999999L), file.path(child_dir, "status.json"))
  expect_error(dragon_delete_run("20260914-000000-child", runs_dir = base), "is running")
  dragonfarm:::write_json(list(state = "succeeded"), file.path(child_dir, "status.json"))
  dragon_delete_run("20260914-000000-child", runs_dir = base)
  expect_false(dir.exists(child_dir))
  expect_equal(nrow(dragon_runs(base)), 0)

  expect_error(dragon_delete_run("nope", runs_dir = base), "No run at")
})

test_that("cancelling a finished run is a no-op", {
  run <- dragon_run(copy_fixture_run())
  expect_message(dragon_cancel(run), "already succeeded")
})

test_that("reproduction code is generated", {
  run <- dragon_run(copy_fixture_run())
  code <- dragon_code(run)
  expect_match(code, "library(dragonfarm)", fixed = TRUE)
  expect_match(code, 'model = "HuggingFaceTB/SmolLM2-135M-Instruct"', fixed = TRUE)
  expect_match(code, "max_steps = 12", fixed = TRUE)
  expect_match(code, 'prompt = "{subject}\\n\\n{body}"', fixed = TRUE)
  expect_match(code, "gradient_checkpointing = TRUE", fixed = TRUE)
  parsed <- parse(text = code)
  expect_true(length(parsed) >= 2)
})

test_that("generate resolves targets without Python", {
  run <- dragon_run(copy_fixture_run())
  t <- dragonfarm:::resolve_target(run)
  expect_equal(t$model, "HuggingFaceTB/SmolLM2-135M-Instruct")
  expect_true(file.exists(file.path(t$adapter, "adapter_config.json")))
  t2 <- dragonfarm:::resolve_target(file.path(run$dir, "adapter"))
  expect_equal(t2$model, "HuggingFaceTB/SmolLM2-135M-Instruct")
  t3 <- dragonfarm:::resolve_target("Qwen/Qwen2.5-0.5B-Instruct")
  expect_null(t3$adapter)
  expect_error(dragonfarm:::resolve_target(tempdir()), "neither")
})

test_that("evaluate reads saved results without Python", {
  run <- dragon_run(copy_fixture_run())
  ev <- dragon_evaluate(run)
  expect_equal(round(ev$eval_loss, 3), 1.644)
  expect_equal(nrow(ev$samples), 2)
  expect_message(print(ev), "perplexity")
})

test_that("gated models need a token", {
  ds <- dragon_map(dragon_dataset(toy_df()), prompt = "subject", response = "reply")
  withr_env <- function(code) {
    old <- Sys.getenv(c("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HF_HOME"), unset = NA)
    Sys.unsetenv(c("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"))
    Sys.setenv(HF_HOME = tempfile())
    on.exit({
      for (nm in names(old)) if (is.na(old[[nm]])) Sys.unsetenv(nm) else do.call(Sys.setenv, as.list(old[nm]))
    })
    code
  }
  skip_if(file.exists(file.path(path.expand("~"), ".cache", "huggingface", "token")), "a Hugging Face token is cached")
  withr_env(expect_error(dragon_train(ds, "google/gemma-3-1b-it", runs_dir = tempfile()), "gated"))
})

test_that("re-evaluating frees this session's own loaded model first", {
  run <- dragon_run(copy_fixture_run())
  dir.create(file.path(run$dir, "adapter"), showWarnings = FALSE)
  writeLines("{}", file.path(run$dir, "adapter", "adapter_config.json"))
  order <- character()
  local_mocked_bindings(worker_alive = function() TRUE,
                        dragon_worker_stop = function(...) { order <<- c(order, "stop"); invisible(TRUE) },
                        require_gpu_free = function(...) { order <<- c(order, "guard"); invisible(TRUE) },
                        run_python = function(...) { order <<- c(order, "evaluate"); list(status = 0L) })
  suppressMessages(dragon_evaluate(run, recompute = TRUE))
  expect_equal(order, c("stop", "guard", "evaluate"))
})
