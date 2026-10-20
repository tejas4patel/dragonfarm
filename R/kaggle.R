# Kaggle without the browser. With the user's Kaggle API key (kaggle.json,
# or KAGGLE_USERNAME with KAGGLE_KEY or a newer API token), dragonfarm uploads the packed run as a
# private dataset, starts the notebook on a GPU, waits for it, downloads the
# output and imports it: one click in the app. The Kaggle command-line tool
# comes from PyPI and runs in a cached environment of its own (reticulate's
# uv_run_tool()), so it never touches the training environment. Everything
# sent goes through the outbound gateway and is recorded.

kaggle_json_path <- function() {
  file.path(Sys.getenv("KAGGLE_CONFIG_DIR", file.path(path.expand("~"), ".kaggle")), "kaggle.json")
}

kaggle_ready <- function() {
  (nzchar(Sys.getenv("KAGGLE_USERNAME")) && nzchar(Sys.getenv("KAGGLE_KEY"))) || nzchar(Sys.getenv("KAGGLE_API_TOKEN")) ||
    file.exists(kaggle_json_path())
}

# Kaggle's newer "Generate New Token" gives one API token (KGAT_...), which
# the Kaggle CLI 2.x reads from KAGGLE_API_TOKEN, not KAGGLE_KEY. A token
# saved in the Key box is passed on under that name.
kaggle_token_env <- function(key = Sys.getenv("KAGGLE_KEY"), token = Sys.getenv("KAGGLE_API_TOKEN")) {
  if (!nzchar(token) && startsWith(key, "KGAT_")) c(KAGGLE_API_TOKEN = key) else character()
}

# Run the Kaggle CLI. Returns list(ok, out) and never throws.
kaggle_cli <- function(args, dir = NULL) {
  if (!is.null(dir)) withr::local_dir(dir)
  # UTF-8 mode: on Windows the CLI otherwise writes the notebook's log in the
  # local code page and crashes on characters it cannot encode.
  out <- withr::with_envvar(c(kaggle_token_env(), PYTHONUTF8 = "1", PYTHONIOENCODING = "utf-8"), tryCatch(
    suppressWarnings(reticulate::uv_run_tool("kaggle", args, stdout = TRUE, stderr = TRUE)),
    error = function(e) structure(conditionMessage(e), status = 1L)))
  list(ok = is.null(attr(out, "status")) || identical(as.integer(attr(out, "status")), 0L), out = as.character(out))
}

# A folder as the Kaggle CLI needs it. Uploads are run from inside the
# folder with "-p .": the CLI's resumable upload names a note after the
# file's path, and a full path both breaks on / under Windows (only
# backslashes are replaced) and can pass the 260-character limit.
kaggle_path <- function(path) normalizePath(path, winslash = "\\", mustWork = FALSE)

# Did a failed CLI call fail because Kaggle refused the credentials?
kaggle_auth_failed <- function(out) {
  any(grepl("401|403|Unauthori[sz]ed|Forbidden|auth login|generate an API token", out, ignore.case = TRUE))
}

# Where a cloud round trip stands, kept in the run's status.json so the app
# (or another R session) can show it.
remote_stage <- function(run, provider, stage, detail = NULL) {
  st <- read_json(run_path(run, "status.json"))
  st$remote <- utils::modifyList(st$remote %||% list(), list(provider = provider, stage = stage, stage_at = now_iso(),
                                                             detail = detail))
  write_json(st, run_path(run, "status.json"))
  invisible(stage)
}

kaggle_stage <- function(run, stage, detail = NULL) remote_stage(run, "kaggle", stage, detail)

# Run a round trip in a background R process that outlives the app.
remote_launch <- function(run, provider, call) {
  script <- run_path(run, "remote", paste0(provider, ".R"))
  writeLines(sprintf("%s; %s", package_loader(), call), script)
  launch_rscript(script, run_path(run, "remote", paste0(provider, ".log")))
}

# Which providers can run with no clicks on this machine, and starting them.
auto_ready <- function(provider) {
  switch(provider, kaggle = kaggle_ready(), lightning = lightning_ready(), FALSE)
}

auto_start <- function(provider, run) {
  switch(provider, kaggle = kaggle_start(run), lightning = lightning_start(run),
         cli::cli_abort("{provider} cannot be run automatically."))
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
  r <- kaggle_cli(c("datasets", "create", "-p", "."), dir = paths$bundle_dir)
  if (!r$ok && any(grepl("already exists", r$out, ignore.case = TRUE))) {
    r <- kaggle_cli(c("datasets", "version", "-p", ".", "-m", shQuote(paste("dragonfarm", now_iso()))), dir = paths$bundle_dir)
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
  r <- kaggle_cli(c("kernels", "push", "-p", "."), dir = paths$dir)
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
  r <- kaggle_cli(c("kernels", "output", kernel, "-p", shQuote(kaggle_path(out_dir))))
  # The results zip is what counts: the CLI can still exit with an error
  # after downloading it (for example while saving the notebook's log).
  zipf <- list.files(out_dir, pattern = "^dragonfarm-results-.*[.]zip$", recursive = TRUE, full.names = TRUE)
  if (!length(zipf)) return(fail("Downloading the results from Kaggle failed.", r$out))
  dragon_import(run, zipf[[1]])
  kaggle_stage(run, "imported")
  TRUE
}

# Start the round trip in a background R process; returns the process.
kaggle_start <- function(run) {
  run <- dragon_run(run)
  if (!kaggle_ready()) {
    cli::cli_abort(c("No Kaggle key found.",
                     "i" = "On kaggle.com: Settings > API > Generate New Token, then save it in Settings, or save kaggle.json in {.path {dirname(kaggle_json_path())}}."),
                   class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  bundle_run(run)   # again, so the Kaggle metadata carries the user's name
  kaggle_stage(run, "queued")
  remote_launch(run, "kaggle", sprintf("dragonfarm:::kaggle_round_trip('%s')", normalizePath(run$dir, winslash = "/")))
}

# One plain line for the app.
remote_stage_label <- function(stage, provider = "kaggle") {
  where <- provider_name(provider)
  switch(stage %||% "",
    queued = "Getting ready...", uploading = sprintf("Uploading the run to %s (private)...", where),
    preparing = sprintf("%s is preparing the upload...", where), starting = sprintf("Starting a GPU on %s...", where),
    running = sprintf("Training on %s...", where), downloading = "Downloading the results...",
    downloaded = "Importing the results...",
    imported = "Done: the results are imported.", failed = sprintf("Something went wrong on %s.", where),
    "")
}
