lightning_run <- function(runs) {
  ds <- dragon_dataset(toy_df())
  suppressMessages(dragon_bundle(dragon_map(ds, "subject", "reply"), "HuggingFaceTB/SmolLM2-135M-Instruct", runs_dir = runs))
}

# Stands in for lightning_trip.py: writes the stages it would, and the results.
fake_trip <- function(outcome = c("ok", "failed", "crash")) {
  outcome <- match.arg(outcome)
  function(args) {
    run_dir <- gsub("^'|'$|^\"|\"$", "", args[2])
    run <- dragonfarm:::new_run(run_dir)
    if (outcome == "crash") return(list(ok = FALSE, out = c("Traceback ...", "ImportError: no module")))
    dragonfarm:::remote_stage(run, "lightning", "running")
    if (outcome == "failed") {
      dragonfarm:::remote_stage(run, "lightning", "failed", "RuntimeError: no T4 available")
      return(list(ok = FALSE, out = "failed"))
    }
    f <- file.path(run_dir, "remote", sprintf("dragonfarm-results-%s.zip", basename(run_dir)))
    writeLines("zip", f)
    dragonfarm:::remote_stage(run, "lightning", "downloaded", f)
    list(ok = TRUE, out = "done")
  }
}

test_that("a Lightning round trip imports the downloaded results and records the upload", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  run <- lightning_run(runs)
  imported <- NULL
  testthat::local_mocked_bindings(lightning_python = fake_trip("ok"),
                                  dragon_import = function(run, results) { imported <<- results; invisible(run) })
  expect_true(dragonfarm:::lightning_round_trip(run))
  expect_match(imported, "dragonfarm-results-")
  expect_equal(jsonlite::read_json(file.path(run$dir, "status.json"))$remote$stage, "imported")
  ev <- dragonfarm:::store_events(5, kind = "outbound", runs_dir = runs)
  expect_equal(ev$name, "lightning.ai")
})

test_that("Lightning failures keep their reason, and a crash still says something", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  run <- lightning_run(runs)
  testthat::local_mocked_bindings(lightning_python = fake_trip("failed"))
  expect_false(dragonfarm:::lightning_round_trip(run))
  expect_match(jsonlite::read_json(file.path(run$dir, "status.json"))$remote$detail, "no T4")
  testthat::local_mocked_bindings(lightning_python = fake_trip("crash"))
  expect_false(dragonfarm:::lightning_round_trip(run))
  st <- jsonlite::read_json(file.path(run$dir, "status.json"))$remote
  expect_equal(st$stage, "failed"); expect_match(st$detail, "ImportError")
  expect_match(dragonfarm:::remote_stage_label("running", "lightning"), "Training on Lightning AI")
})

test_that("without Lightning keys it says where to find them; providers report readiness", {
  withr::local_envvar(LIGHTNING_USER_ID = "", LIGHTNING_API_KEY = "")
  expect_false(dragonfarm:::lightning_ready())
  expect_false(dragonfarm:::auto_ready("lightning")); expect_false(dragonfarm:::auto_ready("colab"))
  expect_error(dragonfarm:::lightning_start(structure(list(dir = tempdir(), id = "x"), class = "dragon_run")), "Keys page")
  withr::local_envvar(LIGHTNING_USER_ID = "u", LIGHTNING_API_KEY = "k")
  expect_true(dragonfarm:::auto_ready("lightning"))
})
