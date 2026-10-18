bundled_run <- function(runs = tempfile("runs-"), n = 40) {
  ds <- dragon_map(dragon_dataset(toy_df(n)), "subject", "reply")
  suppressMessages(dragon_bundle(ds, "HuggingFaceTB/SmolLM2-135M-Instruct", runs_dir = runs))
}

# A results zip like the one the notebook's last cell produces, built from the
# finished-run fixture, addressed to `run_id`.
results_zip_for <- function(run, run_id = run$id) {
  fx <- copy_fixture_run()
  staging <- tempfile("results-")
  dir.create(staging)
  dragonfarm:::write_json(
    list(format = "dragonfarm-results", version = 1L, run_id = run_id, state = "succeeded", device = "Tesla T4"),
    file.path(staging, "dragonfarm-results.json")
  )
  for (f in c("status.json", "progress.jsonl", "log.txt", "eval.json", "samples.json")) {
    file.copy(file.path(fx, f), file.path(staging, f))
  }
  file.copy(file.path(fx, "adapter"), staging, recursive = TRUE)
  zf <- tempfile(fileext = ".zip")
  zip::zip(zf, files = list.files(staging), root = staging)
  zf
}

test_that("provider table and links are well formed", {
  p <- dragon_remote_providers()
  expect_equal(p$provider, c("colab", "kaggle", "lightning", "runpod"))
  expect_match(dragonfarm:::remote_url("colab"), "^https://colab\\.research\\.google\\.com/github/.*dragonfarm_remote\\.ipynb$")
  expect_match(dragonfarm:::remote_url("kaggle"), "^https://www\\.kaggle\\.com/kernels/welcome\\?src=https://github\\.com/")
  expect_match(dragonfarm:::remote_url("lightning"), "^https://lightning\\.ai/new\\?repo_url=https%3A%2F%2Fgithub\\.com")
  expect_match(dragonfarm:::remote_url("runpod"), "runpod")
  expect_error(dragonfarm:::remote_url("aws"), "must be one of")
})

test_that("dragon_bundle writes a run and a self-contained zip without Python", {
  runs <- tempfile("runs-")
  run <- bundled_run(runs)
  expect_s3_class(run, "dragon_run")
  expect_equal(dragon_status(run)$state, "bundled")
  expect_true(run$id %in% dragon_runs(runs)$id)

  paths <- dragonfarm:::bundle_paths(run)
  expect_true(file.exists(paths$zip))
  files <- zip::zip_list(paths$zip)$filename
  expect_true(all(c(
    "run/config.json", "run/dataset.json", "run/status.json", "run/data/train.jsonl", "run/data/eval.jsonl",
    "python/dragonfarm/train.py", "python/dragonfarm/pack_results.py", "python/dragonfarm/hardware.py",
    "requirements.txt", "dragonfarm_remote.ipynb", "README.md"
  ) %in% files))
  expect_false(any(grepl("__pycache__|checkpoints|adapter", files)))

  tmp <- tempfile()
  zip::unzip(paths$zip, files = c("run/config.json", "run/status.json", "requirements.txt"), exdir = tmp)
  cfg <- dragonfarm:::read_json(file.path(tmp, "run", "config.json"))
  expect_equal(cfg$hardware$device, "auto")
  expect_equal(cfg$run_id, run$id)
  expect_equal(dragonfarm:::read_json(file.path(tmp, "run", "status.json"))$state, "queued")
  expect_true(any(grepl("^torch", readLines(file.path(tmp, "requirements.txt")))))

  st <- dragon_status(run)
  expect_equal(st$remote$bundle, paths$zip)
})

test_that("bundling writes Kaggle CLI metadata that agrees with itself", {
  withr::local_envvar(KAGGLE_USERNAME = "someone")
  run <- bundled_run()
  paths <- dragonfarm:::bundle_paths(run)
  km <- dragonfarm:::read_json(paths$kernel_meta)
  dm <- dragonfarm:::read_json(paths$dataset_meta)
  expect_true(km$enable_gpu)
  expect_true(km$enable_internet)
  expect_true(km$is_private)
  expect_equal(km$code_file, "dragonfarm_remote.ipynb")
  expect_equal(km$dataset_sources[[1]], dm$id)
  expect_match(dm$id, "^someone/dragonfarm-")
  slug <- sub("^.*/", "", dm$id)
  expect_lte(nchar(slug), 50)
  expect_false(grepl("-$", slug))
  expect_true(file.exists(paths$notebook))
  expect_true(file.exists(paths$readme))
  expect_true(any(grepl("## Kaggle", readLines(paths$readme))))
})

test_that("dragon_remote reports steps for every provider without opening a browser", {
  run <- bundled_run()
  res <- suppressMessages(dragon_remote(run, "kaggle", open = FALSE))
  expect_equal(res$provider, "kaggle")
  expect_true(file.exists(res$bundle))
  expect_true(any(grepl("Accelerator", res$steps)))
  expect_true(any(grepl("dragon_import\\(dragon_run\\(", res$steps)))
  expect_true(any(grepl("kaggle kernels push", res$steps)))
  st <- dragon_status(run)
  expect_equal(st$remote$provider, "kaggle")
  expect_equal(st$remote$url, res$url)
  for (p in c("colab", "lightning", "runpod")) {
    r <- suppressMessages(dragon_remote(run, p, open = FALSE))
    expect_type(r$steps, "character")
    expect_true(any(grepl(dragonfarm:::results_name(run), r$steps, fixed = TRUE)))
  }
  expect_error(suppressMessages(dragon_remote(run, "aws", open = FALSE)))
})

test_that("dragon_remote re-bundles a finished run on demand and keeps its state", {
  run <- bundled_run()
  suppressMessages(dragon_import(run, results_zip_for(run)))
  expect_equal(dragon_status(run)$state, "succeeded")
  unlink(dragonfarm:::bundle_paths(run)$dir, recursive = TRUE)
  res <- suppressMessages(dragon_remote(run, "colab", open = FALSE))
  expect_true(file.exists(res$bundle))
  expect_equal(dragon_status(run)$state, "succeeded")
  files <- zip::zip_list(res$bundle)$filename
  expect_true("run/data/train.jsonl" %in% files)
  expect_false(any(grepl("^run/adapter", files)))
})

test_that("a run with no data files cannot be bundled", {
  run <- dragon_run(copy_fixture_run())
  expect_error(dragonfarm:::bundle_run(run), "missing")
})

test_that("dragon_import brings cloud results back into the run", {
  run <- bundled_run()
  zf <- results_zip_for(run)
  msgs <- testthat::capture_messages(dragon_import(run, zf))
  expect_true(any(grepl("succeeded", msgs)))
  expect_true(any(grepl("dragon_generate", msgs)))
  st <- dragon_status(run)
  expect_equal(st$state, "succeeded")
  expect_null(st$pid)
  expect_false(is.null(st$imported_at))
  expect_equal(st$remote$results, normalizePath(zf, winslash = "/"))
  expect_equal(nrow(dragon_progress(run)), 5)
  expect_true(file.exists(file.path(run$dir, "adapter", "adapter_config.json")))
  ev <- dragon_evaluate(run)
  expect_equal(ev$eval_loss, dragonfarm:::read_json(fixture_path("run1", "eval.json"))$eval_loss)
  expect_length(dragon_logs(run, 2), 2)
})

test_that("dragon_import accepts an unpacked directory too", {
  run <- bundled_run()
  zf <- results_zip_for(run)
  dir <- tempfile("unpacked-")
  zip::unzip(zf, exdir = dir)
  suppressMessages(dragon_import(run, dir))
  expect_equal(dragon_status(run)$state, "succeeded")
})

test_that("dragon_import rejects archives that are not results and warns on a run mismatch", {
  run <- bundled_run()
  bad <- tempfile(fileext = ".zip")
  staging <- tempfile(); dir.create(staging)
  writeLines("x", file.path(staging, "whatever.txt"))
  zip::zip(bad, files = "whatever.txt", root = staging)
  expect_error(dragon_import(run, bad), "not a dragonfarm results archive")
  expect_error(dragon_import(run, tempfile()), "does not exist")

  other <- results_zip_for(run, run_id = "some-other-run")
  expect_warning(suppressMessages(dragon_import(run, other)), "different run")
  expect_equal(dragon_status(run)$state, "succeeded")
})

test_that("dragon_wait refuses to wait on a bundled run", {
  run <- bundled_run()
  expect_error(dragon_wait(run, timeout = 1), "bundled for a cloud GPU")
})

test_that("the hosted notebook is valid and runs the trainer and the packer", {
  path <- system.file("remote", "dragonfarm_remote.ipynb", package = "dragonfarm")
  expect_true(nzchar(path))
  nb <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  expect_equal(nb$nbformat, 4)
  src <- paste(unlist(lapply(nb$cells, function(cell) cell$source)), collapse = "")
  expect_match(src, "dragonfarm.train", fixed = TRUE)
  expect_match(src, "dragonfarm.pack_results", fixed = TRUE)
  expect_match(src, "/kaggle/input", fixed = TRUE)
  expect_match(src, "google.colab", fixed = TRUE)
  expect_match(src, "HF_TOKEN", fixed = TRUE)
})

test_that("the train module can prepare a cloud bundle", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  ds <- dragon_dataset(toy_df())
  state <- shiny::reactiveValues(
    dataset = ds, mapped = dragon_map(ds, "subject", "reply"),
    model = list(id = "HuggingFaceTB/SmolLM2-135M-Instruct", trust_remote_code = FALSE),
    run = NULL, hardware = NULL, cloud = NULL
  )
  shiny::testServer(dragonfarm:::mod_train_server, args = list(state = state, nav_to = function(p) NULL), {
    session$setInputs(epochs = 1, learning_rate = 2e-4, rank = 8, max_seq_len = 256, batch_size = 2, grad_accum = 1,
                      alpha = 16, dropout = 0.05, max_steps = NA, eval_frac = 0.1, save_steps = 10, seed = 1,
                      device = "auto", dtype = "auto", grad_ckpt = FALSE, name = "", provider = "colab")
    session$setInputs(bundle = 1)
    expect_s3_class(state$run, "dragon_run")
    expect_equal(dragon_status(state$run)$state, "bundled")
    expect_equal(state$cloud$provider, "colab")
    expect_true(file.exists(state$cloud$bundle))
  })
})

test_that("steps shown in the app never ask for code, and Colab needs no runtime change", {
  run <- structure(list(dir = "C:/runs/r1", id = "r1"), class = "dragon_run")
  paths <- list(zip = "C:/runs/r1/remote/bundle/dragonfarm-r1.zip", bundle_dir = "b", dir = "d")
  for (p in c("colab", "kaggle", "lightning", "runpod")) {
    s <- dragonfarm:::remote_steps(p, run, paths, app = TRUE, saved = TRUE)
    expect_false(any(grepl("dragon_import|kaggle datasets|kaggle kernels|[(][)]", s)), info = p)
    expect_true(any(grepl("Downloads", s)), info = p)
  }
  colab <- dragonfarm:::remote_steps("colab", run, paths, app = TRUE, saved = TRUE)
  expect_length(colab, 4)
  expect_false(any(grepl("Change runtime type", colab)))
  expect_true(any(grepl("dragon_import", dragonfarm:::remote_steps("colab", run, paths))))   # the R console keeps its line
})

test_that("results that land in Downloads are found; unfinished downloads are not", {
  d <- withr::local_tempdir()
  withr::local_options(dragonfarm.downloads_dir = d)
  run <- structure(list(dir = d, id = "20261017-r1"), class = "dragon_run")
  expect_null(dragonfarm:::find_results(run))
  file.create(file.path(d, "dragonfarm-results-20261017-r1.zip.crdownload"))
  file.create(file.path(d, "dragonfarm-results-other.zip"))
  expect_null(dragonfarm:::find_results(run))
  file.create(file.path(d, "dragonfarm-results-20261017-r1 (1).zip"))
  expect_match(dragonfarm:::find_results(run), "r1 [(]1[)][.]zip$")
  expect_null(dragonfarm:::find_results(run, since = Sys.time() + 3600))
  src <- withr::local_tempfile(fileext = ".zip"); writeLines("x", src)
  expect_equal(dragonfarm:::save_to_downloads(src), file.path(d, basename(src)))
  withr::local_options(dragonfarm.downloads_dir = file.path(d, "missing"))
  expect_null(dragonfarm:::save_to_downloads(src))
})

test_that("only a browser on this machine counts as local", {
  s <- function(h) list(clientData = list(url_hostname = h))
  expect_true(dragonfarm:::is_local_session(s("127.0.0.1")))
  expect_true(dragonfarm:::is_local_session(s("localhost")))
  expect_false(dragonfarm:::is_local_session(s("connect.example.com")))
})

test_that("the notebook asks Colab and Kaggle for a GPU itself", {
  nb <- jsonlite::read_json(system.file("remote", "dragonfarm_remote.ipynb", package = "dragonfarm"))
  expect_equal(nb$metadata$accelerator, "GPU")
  expect_equal(nb$metadata$colab$gpuType, "T4")
  expect_true(nb$metadata$kaggle$isGpuEnabled); expect_true(nb$metadata$kaggle$isInternetEnabled)
})

test_that("one click on this machine saves the run to Downloads, opens the notebook, and imports the results", {
  runs <- withr::local_tempdir()
  dl <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs, dragonfarm.downloads_dir = dl)
  opened <- NULL; imported <- NULL
  testthat::local_mocked_bindings(
    is_local_session = function(session) TRUE,
    open_in_browser = function(url) opened <<- url,
    dragon_import = function(run, results) { imported <<- results; invisible(run) }
  )
  ds <- dragon_dataset(toy_df())
  state <- shiny::reactiveValues(dataset = ds, mapped = dragon_map(ds, "subject", "reply"),
                                 model = list(id = "HuggingFaceTB/SmolLM2-135M-Instruct", trust_remote_code = FALSE),
                                 run = NULL, hardware = NULL, cloud = NULL)
  shiny::testServer(dragonfarm:::mod_train_server, args = list(state = state, nav_to = function(p) NULL), {
    session$setInputs(epochs = 1, learning_rate = 2e-4, rank = 8, max_seq_len = 256, batch_size = 2, grad_accum = 1,
                      alpha = 16, dropout = 0.05, max_steps = NA, eval_frac = 0.1, save_steps = 10, seed = 1,
                      device = "auto", dtype = "auto", grad_ckpt = FALSE, name = "", provider = "colab")
    session$setInputs(bundle = 1)
    expect_true(file.exists(file.path(dl, basename(state$cloud$bundle))))     # saved where the file picker opens
    expect_match(opened, "colab.research.google.com")
    expect_false(any(grepl("dragon_import", state$cloud$steps)))
    expect_match(output$cloud_ready$html, "Waiting for the results")
    results <- file.path(dl, sprintf("dragonfarm-results-%s.zip", state$run$id))
    writeLines("zip", results)
    session$elapse(6000)
    expect_equal(normalizePath(imported), normalizePath(results))
    expect_true(state$cloud$imported)
    expect_match(output$cloud_ready$html, "Results imported")
  })
})
