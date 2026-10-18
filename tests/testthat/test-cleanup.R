# G7 cleanup proposal: checkpoints of finished runs, removed only on request.

ck_run <- function(runs, id, state = "succeeded", adapter = TRUE, mb = 1) {
  d <- file.path(runs, id)
  dir.create(file.path(d, "checkpoints", "checkpoint-10"), recursive = TRUE)
  writeBin(raw(mb * 1e6), file.path(d, "checkpoints", "checkpoint-10", "optimizer.pt"))
  if (adapter) { dir.create(file.path(d, "adapter")); writeBin(raw(1000), file.path(d, "adapter", "adapter_model.safetensors")) }
  jsonlite::write_json(list(model = list(id = "m")), file.path(d, "config.json"), auto_unbox = TRUE)
  jsonlite::write_json(list(state = state), file.path(d, "status.json"), auto_unbox = TRUE)
  d
}

test_that("only succeeded runs with their adapter are proposed, largest first", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  ck_run(runs, "r-done-small", mb = 1); ck_run(runs, "r-done-big", mb = 3)
  ck_run(runs, "r-failed", state = "failed"); ck_run(runs, "r-running", state = "running")
  ck_run(runs, "r-no-adapter", adapter = FALSE)
  fc <- dragonfarm:::finished_checkpoints(dragon_runs(runs))
  expect_equal(fc$id, c("r-done-big", "r-done-small"))
  expect_equal(fc$bytes, c(3e6, 1e6))
})

test_that("removal takes only the checkpoints, re-checks each run, and is recorded", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  d <- ck_run(runs, "r-done", mb = 2); f <- ck_run(runs, "r-failed", state = "failed")
  res <- dragonfarm:::remove_finished_checkpoints(c("r-done", "r-failed"), runs_dir = runs)
  expect_equal(res$removed, "r-done"); expect_equal(res$bytes, 2e6)
  expect_false(dir.exists(file.path(d, "checkpoints")))
  expect_true(file.exists(file.path(d, "adapter", "adapter_model.safetensors")))   # the trained model stays
  expect_true(dir.exists(file.path(f, "checkpoints")))                             # a failed run can still resume
  ev <- dragonfarm:::store_events(1, kind = "cleanup", runs_dir = runs)
  det <- jsonlite::fromJSON(ev$detail)
  expect_equal(det$runs, "r-done"); expect_equal(det$skipped, "r-failed"); expect_equal(det$bytes, 2e6)
})

test_that("Monitor proposes the cleanup and removes only after confirmation", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  d <- ck_run(runs, "20261018-done", mb = 2)
  state <- shiny::reactiveValues(run = NULL, dataset = NULL)
  shiny::testServer(dragonfarm:::mod_monitor_server, args = list(state = state, runs_dir = runs), {
    expect_match(output$space$html, "Checkpoints in 1 finished run take 2 MB")
    session$setInputs(clean_ck = 1)
    expect_true(dir.exists(file.path(d, "checkpoints")))                           # asking is not doing
    session$setInputs(clean_ck_confirm = 1)
    expect_false(dir.exists(file.path(d, "checkpoints")))
    expect_false(grepl("Checkpoints in", output$space$html))
  })
})
