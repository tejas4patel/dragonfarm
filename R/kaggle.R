# Kaggle without the browser. With the user's Kaggle API key (kaggle.json,
# or KAGGLE_USERNAME and KAGGLE_KEY), dragonfarm uploads the packed run as a
# private dataset, starts the notebook on a GPU, waits for it, downloads the
# output and imports it: one click in the app. The Kaggle command-line tool
# comes from PyPI and runs in a cached environment of its own (reticulate's
# uv_run_tool()), so it never touches the training environment. Everything
# sent goes through the outbound gateway and is recorded.

kaggle_json_path <- function() {
  file.path(Sys.getenv("KAGGLE_CONFIG_DIR", file.path(path.expand("~"), ".kaggle")), "kaggle.json")
}

kaggle_ready <- function() {
  (nzchar(Sys.getenv("KAGGLE_USERNAME")) && nzchar(Sys.getenv("KAGGLE_KEY"))) || file.exists(kaggle_json_path())
}

# Run the Kaggle CLI. Returns list(ok, out) and never throws.
kaggle_cli <- function(args) {
  out <- tryCatch(suppressWarnings(reticulate::uv_run_tool("kaggle", args, stdout = TRUE, stderr = TRUE)),
                  error = function(e) structure(conditionMessage(e), status = 1L))
  list(ok = is.null(attr(out, "status")) || identical(as.integer(attr(out, "status")), 0L), out = as.character(out))
}

# Where a Kaggle round trip stands, kept in the run's status.json so the app
# (or another R session) can show it.
kaggle_stage <- function(run, stage, detail = NULL) {
  st <- read_json(run_path(run, "status.json"))
  st$remote <- utils::modifyList(st$remote %||% list(), list(provider = "kaggle", stage = stage, stage_at = now_iso(),
                                                             detail = detail))
  write_json(st, run_path(run, "status.json"))
  invisible(stage)
}

kaggle_status_of <- function(out) {
  s <- tolower(paste(out, collapse = " "))
  if (grepl("complete", s)) "complete"
  else if (grepl("error|fail", s)) "error"
  else if (grepl("cancel", s)) "cancelled"
  else if (grepl("running", s)) "running"
  else if (grepl("queued|pending", s)) "queued"
  else "unknown"
}

# The whole round trip; meant for a background R process (kaggle_start()).
# `wait` and `poll` are seconds.
kaggle_round_trip <- function(run, poll = 60, max_hours = 12, dataset_wait = 600) {
  run <- dragon_run(run)
  paths <- bundle_paths(run)
  if (!file.exists(paths$zip)) paths <- bundle_run(run)
  ds <- kaggle_dataset_metadata(run)$id
  fail <- function(msg, out = NULL) {
    kaggle_stage(run, "failed", paste(c(msg, utils::tail(out, 5)), collapse = "\n"))
    FALSE
  }

  kaggle_stage(run, "uploading")
  outbound_check("https://www.kaggle.com", sprintf("Kaggle: upload run %s as a private dataset and train it on a GPU", run$id),
                 bytes = file.size(paths$zip), runs_dir = dirname(run$dir))
  r <- kaggle_cli(c("datasets", "create", "-p", shQuote(paths$bundle_dir)))
  if (!r$ok && any(grepl("already exists", r$out, ignore.case = TRUE))) {
    r <- kaggle_cli(c("datasets", "version", "-p", shQuote(paths$bundle_dir), "-m", shQuote(paste("dragonfarm", now_iso()))))
  }
  if (!r$ok) return(fail("Uploading the run to Kaggle failed.", r$out))

  kaggle_stage(run, "preparing")
  t0 <- Sys.time()
  repeat {
    s <- kaggle_cli(c("datasets", "status", ds))
    if (s$ok && any(grepl("ready", s$out, ignore.case = TRUE))) break
    if (as.numeric(difftime(Sys.time(), t0, units = "secs")) > dataset_wait) return(fail("Kaggle did not finish preparing the upload.", s$out))
    Sys.sleep(min(poll, 15))
  }

  kaggle_stage(run, "starting")
  r <- kaggle_cli(c("kernels", "push", "-p", shQuote(paths$dir)))
  if (!r$ok) return(fail("Starting the notebook on Kaggle failed.", r$out))
  kernel <- kaggle_kernel_metadata(run)$id

  t0 <- Sys.time()
  repeat {
    Sys.sleep(poll)
    s <- kaggle_cli(c("kernels", "status", kernel))
    state <- if (s$ok) kaggle_status_of(s$out) else "unknown"
    if (state %in% c("queued", "running", "unknown")) kaggle_stage(run, if (state == "unknown") "running" else state)
    if (state == "complete") break
    if (state %in% c("error", "cancelled")) return(fail(sprintf("The Kaggle notebook ended with %s.", state), s$out))
    if (as.numeric(difftime(Sys.time(), t0, units = "hours")) > max_hours) return(fail("The Kaggle notebook ran too long."))
  }

  kaggle_stage(run, "downloading")
  out_dir <- tempfile("kaggle-output-")
  dir.create(out_dir)
  r <- kaggle_cli(c("kernels", "output", kernel, "-p", shQuote(out_dir)))
  zipf <- list.files(out_dir, pattern = "^dragonfarm-results-.*[.]zip$", recursive = TRUE, full.names = TRUE)
  if (!r$ok || !length(zipf)) return(fail("Downloading the results from Kaggle failed.", r$out))
  dragon_import(run, zipf[[1]])
  kaggle_stage(run, "imported")
  TRUE
}

# Start the round trip in a background R process; returns the process.
kaggle_start <- function(run) {
  run <- dragon_run(run)
  if (!kaggle_ready()) {
    cli::cli_abort(c("No Kaggle key found.",
                     "i" = "On kaggle.com: Settings > API > Create New Token, then save kaggle.json in {.path {dirname(kaggle_json_path())}}."),
                   class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  bundle_run(run)   # again, so the Kaggle metadata carries the user's name
  kaggle_stage(run, "queued")
  script <- run_path(run, "remote", "kaggle.R")
  writeLines(sprintf("%s; dragonfarm:::kaggle_round_trip('%s')", package_loader(), normalizePath(run$dir, winslash = "/")), script)
  launch_rscript(script, run_path(run, "remote", "kaggle.log"))
}

# One plain line for the app.
kaggle_stage_label <- function(stage) {
  switch(stage %||% "",
    queued = "Getting ready...", uploading = "Uploading the run to Kaggle (private)...",
    preparing = "Kaggle is preparing the upload...", starting = "Starting the notebook on a Kaggle GPU...",
    running = "Training on Kaggle...", downloading = "Downloading the results...",
    imported = "Done: the results are imported.", failed = "Something went wrong on Kaggle.",
    "")
}
