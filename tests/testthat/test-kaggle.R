kaggle_run <- function(runs) {
  withr::local_envvar(KAGGLE_USERNAME = "ana", KAGGLE_KEY = "test-key", .local_envir = parent.frame())
  ds <- dragon_dataset(toy_df())
  suppressMessages(dragon_bundle(dragon_map(ds, "subject", "reply"), "HuggingFaceTB/SmolLM2-135M-Instruct", runs_dir = runs))
}

# A stand-in for the Kaggle CLI: answers each command from a script.
fake_kaggle <- function(statuses = c("running", "complete"), push_ok = TRUE, exists = FALSE, run_id) {
  calls <- character()
  k <- 0
  f <- function(args) {
    cmd <- paste(args[1:2], collapse = " ")
    calls <<- c(calls, cmd)
    switch(cmd,
      "datasets create" = if (exists) list(ok = FALSE, out = "Dataset already exists") else list(ok = TRUE, out = "created"),
      "datasets version" = list(ok = TRUE, out = "new version"),
      "datasets status" = list(ok = TRUE, out = "ready"),
      "kernels push" = if (push_ok) list(ok = TRUE, out = "pushed") else list(ok = FALSE, out = "403 - phone verification required"),
      "kernels status" = { k <<- k + 1; list(ok = TRUE, out = sprintf('ana/x has status "%s"', statuses[min(k, length(statuses))])) },
      "kernels output" = {
        d <- gsub("^'|'$|^\"|\"$", "", args[length(args)])
        writeLines("zip", file.path(d, sprintf("dragonfarm-results-%s.zip", run_id)))
        list(ok = TRUE, out = "downloaded")
      })
  }
  list(f = f, calls = function() calls)
}

test_that("a Kaggle round trip uploads, starts, waits, downloads and imports, and says where it is", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  run <- kaggle_run(runs)
  k <- fake_kaggle(run_id = run$id)
  stages <- character(); imported <- NULL
  testthat::local_mocked_bindings(
    kaggle_cli = k$f,
    dragon_import = function(run, results) { imported <<- results; invisible(run) },
    kaggle_stage = function(run, stage, detail = NULL) { stages <<- c(stages, stage); invisible(stage) }
  )
  expect_true(dragonfarm:::kaggle_round_trip(run, poll = 0))
  expect_equal(k$calls(), c("datasets create", "datasets status", "kernels push", "kernels status", "kernels status", "kernels output"))
  expect_equal(stages, c("uploading", "preparing", "starting", "running", "downloading", "imported"))
  expect_match(imported, "dragonfarm-results-")
  ev <- dragonfarm:::store_events(5, kind = "outbound", runs_dir = runs)
  expect_equal(ev$name, "www.kaggle.com"); expect_match(ev$detail, "private dataset")
})

test_that("an existing dataset gets a new version, and failures stop with the reason", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  run <- kaggle_run(runs)
  k <- fake_kaggle(exists = TRUE, push_ok = FALSE, run_id = run$id)
  testthat::local_mocked_bindings(kaggle_cli = k$f)
  expect_false(dragonfarm:::kaggle_round_trip(run, poll = 0))
  expect_true("datasets version" %in% k$calls())
  st <- jsonlite::read_json(file.path(run$dir, "status.json"))
  expect_equal(st$remote$stage, "failed"); expect_match(st$remote$detail, "phone verification")
  expect_match(dragonfarm:::remote_stage_label("failed", "kaggle"), "went wrong on Kaggle")
})

test_that("Kaggle statuses are read plainly", {
  s <- dragonfarm:::kaggle_status_of
  expect_equal(s('ana/x has status "KernelWorkerStatus.COMPLETE"'), "complete")
  expect_equal(s('ana/x has status "running"'), "running")
  expect_equal(s('ana/x has status "queued"'), "queued")
  expect_equal(s('ana/x has status "error"'), "error")
})

test_that("without a Kaggle key it says how to get one", {
  withr::local_envvar(KAGGLE_USERNAME = "", KAGGLE_KEY = "", KAGGLE_API_TOKEN = "", KAGGLE_CONFIG_DIR = withr::local_tempdir())
  expect_false(dragonfarm:::kaggle_ready())
  expect_error(dragonfarm:::kaggle_start(structure(list(dir = tempdir(), id = "x"), class = "dragon_run")), "Generate New Token")
})

test_that("a newer Kaggle API token in the Key box reaches the CLI as KAGGLE_API_TOKEN", {
  expect_equal(dragonfarm:::kaggle_token_env(key = "KGAT_abc", token = ""), c(KAGGLE_API_TOKEN = "KGAT_abc"))
  expect_length(dragonfarm:::kaggle_token_env(key = "0123456789abcdef0123456789abcdef", token = ""), 0)
  expect_length(dragonfarm:::kaggle_token_env(key = "KGAT_abc", token = "KGAT_set"), 0)
  withr::local_envvar(KAGGLE_KEY = "KGAT_abc", KAGGLE_API_TOKEN = "", KAGGLE_USERNAME = "ana")
  seen <- NULL
  testthat::local_mocked_bindings(uv_run_tool = function(...) { seen <<- Sys.getenv("KAGGLE_API_TOKEN"); "ok" }, .package = "reticulate")
  expect_true(dragonfarm:::kaggle_cli("--version")$ok)
  expect_equal(seen, "KGAT_abc")
  expect_equal(Sys.getenv("KAGGLE_API_TOKEN"), "")
})

test_that("a Kaggle check only says the key was refused when Kaggle said so", {
  expect_true(dragonfarm:::kaggle_auth_failed(c("401 Client Error: Unauthorized for url")))
  expect_true(dragonfarm:::kaggle_auth_failed(c("Recommended: log in with OAuth", "    kaggle auth login")))
  expect_false(dragonfarm:::kaggle_auth_failed(c("ConnectionError: Max retries exceeded")))
  testthat::local_mocked_bindings(outbound_check = function(...) invisible(TRUE),
                                  kaggle_cli = function(args) list(ok = FALSE, out = "ConnectionError: timed out"))
  expect_match(dragonfarm:::secret_check("kaggle")$message, "Could not reach")
  testthat::local_mocked_bindings(kaggle_cli = function(args) list(ok = FALSE, out = "401 Unauthorized"))
  expect_match(dragonfarm:::secret_check("kaggle")$message, "did not accept")
})
