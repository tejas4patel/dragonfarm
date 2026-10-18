# Lightning AI without the browser. With the user's Lightning keys
# (LIGHTNING_USER_ID and LIGHTNING_API_KEY), dragonfarm starts a Studio on a
# T4, uploads the packed run, trains, downloads the results, stops the Studio
# and imports them: one click in the app. The work is done by
# inst/remote/lightning_trip.py with Lightning's own SDK, pinned and run in a
# cached environment of its own (reticulate's uv_run_tool()), never in the
# training environment.

lightning_sdk_version <- "2026.10.13"

lightning_ready <- function() nzchar(Sys.getenv("LIGHTNING_USER_ID")) && nzchar(Sys.getenv("LIGHTNING_API_KEY"))

# Run the round-trip script. Returns list(ok, out) and never throws.
lightning_python <- function(args) {
  script <- system.file("remote", "lightning_trip.py", package = "dragonfarm")
  out <- tryCatch(suppressWarnings(reticulate::uv_run_tool(
    "python", c(shQuote(script), args), from = "python", with = paste0("lightning_sdk==", lightning_sdk_version),
    python_version = "3.12", stdout = TRUE, stderr = TRUE)),
    error = function(e) structure(conditionMessage(e), status = 1L))
  list(ok = is.null(attr(out, "status")) || identical(as.integer(attr(out, "status")), 0L), out = as.character(out))
}

# The whole round trip; meant for a background R process (lightning_start()).
lightning_round_trip <- function(run, machine = "T4", max_hours = 6) {
  run <- dragon_run(run)
  paths <- bundle_paths(run)
  if (!file.exists(paths$zip)) paths <- bundle_run(run)
  remote_stage(run, "lightning", "starting")
  outbound_check("https://lightning.ai", sprintf("Lightning AI: upload run %s to your Studio and train it on a %s GPU", run$id, machine),
                 bytes = file.size(paths$zip), runs_dir = dirname(run$dir))
  r <- lightning_python(c(shQuote(paths$zip), shQuote(run$dir), "--machine", machine, "--max-hours", format(max_hours)))
  st <- read_json(run_path(run, "status.json"))$remote
  if (identical(st$stage, "downloaded") && !is.null(st$detail) && file.exists(st$detail)) {
    dragon_import(run, st$detail)
    remote_stage(run, "lightning", "imported")
    return(TRUE)
  }
  if (!identical(st$stage, "failed")) {
    remote_stage(run, "lightning", "failed", paste(c("The Lightning round trip stopped.", utils::tail(r$out, 5)), collapse = "\n"))
  }
  FALSE
}

lightning_start <- function(run) {
  run <- dragon_run(run)
  if (!lightning_ready()) {
    cli::cli_abort(c("No Lightning AI keys found.",
                     "i" = "On lightning.ai, open your profile's Keys page and copy your user id and API key into {.envvar LIGHTNING_USER_ID} and {.envvar LIGHTNING_API_KEY}."),
                   class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  if (!file.exists(bundle_paths(run)$zip)) bundle_run(run)
  remote_stage(run, "lightning", "queued")
  remote_launch(run, "lightning", sprintf("dragonfarm:::lightning_round_trip('%s')", normalizePath(run$dir, winslash = "/")))
}
