# Extracted from test-remote.R:50

# prequel ----------------------------------------------------------------------
bundled_run <- function(runs = tempfile("runs-"), n = 40) {
  ds <- dragon_map(dragon_dataset(toy_df(n)), "subject", "reply")
  suppressMessages(dragon_bundle(ds, "HuggingFaceTB/SmolLM2-135M-Instruct", runs_dir = runs))
}
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

# test -------------------------------------------------------------------------
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
