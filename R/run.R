#' Directory where runs are stored
#'
#' Every function that writes a run (`dragon_train()`, `dragon_bundle()`,
#' the app, and so on) takes a `runs_dir` argument that defaults to this.
#' Without configuration it resolves to a `dragonfarm_runs` folder under a
#' session temp directory, so a fresh R session never writes to your
#' working directory or home filespace by default; that folder disappears
#' once the session ends. For runs you want to keep, set a real location
#' once with `options(dragonfarm.runs_dir = "path/to/dragonfarm_runs")` or
#' the `DRAGONFARM_RUNS_DIR` environment variable, or pass `runs_dir=` to
#' the function you're calling.
#'
#' @return A path.
#' @export
#' @examples
#' dragon_runs_dir()
#' withr::with_options(list(dragonfarm.runs_dir = "~/dragonfarm_runs"), dragon_runs_dir())
dragon_runs_dir <- function() {
  getOption("dragonfarm.runs_dir", Sys.getenv("DRAGONFARM_RUNS_DIR", unset = file.path(tempdir(), "dragonfarm_runs")))
}

new_run <- function(dir, process = NULL) {
  structure(
    list(dir = normalizePath(dir, winslash = "/", mustWork = FALSE), id = basename(dir), process = process),
    class = "dragon_run"
  )
}

#' Reopen an existing run
#'
#' Runs live entirely on disk, so any run can be picked up from a new R
#' session by its directory.
#'
#' @param dir Path to a run directory (one containing `config.json`).
#' @return A `dragon_run` object.
#' @export
dragon_run <- function(dir) {
  if (inherits(dir, "dragon_run")) return(dir)
  check_string(dir, "dir")
  if (!file.exists(file.path(dir, "config.json"))) {
    cli::cli_abort("{.path {dir}} is not a run directory (no config.json).")
  }
  new_run(dir)
}

run_path <- function(run, ...) file.path(run$dir, ...)

run_config <- function(run) read_json(run_path(run, "config.json"))

check_run <- function(run) {
  if (!inherits(run, "dragon_run")) cli::cli_abort("{.arg run} must be a {.cls dragon_run}. Use {.fn dragon_run} to reopen one by path.")
  invisible(run)
}

make_run_id <- function(name) {
  paste0(format(Sys.time(), "%Y%m%d-%H%M%S"), "-", slugify(name))
}

#' List runs
#'
#' @param runs_dir Directory holding run directories.
#' @return A data frame with one row per run, newest first.
#' @export
dragon_runs <- function(runs_dir = dragon_runs_dir()) {
  runs_table(list_run_dirs(runs_dir))
}

#' Archived runs
#'
#' Runs that [dragon_archive_run()] moved out of the way. Same columns as
#' [dragon_runs()].
#'
#' @param runs_dir Where runs live.
#' @return A data frame, one row per archived run.
#' @export
dragon_archived_runs <- function(runs_dir = dragon_runs_dir()) {
  runs_table(list_run_dirs(file.path(runs_dir, "archived")))
}

list_run_dirs <- function(runs_dir) {
  if (!dir.exists(runs_dir)) return(character())
  dirs <- list.dirs(runs_dir, recursive = FALSE, full.names = TRUE)
  dirs[file.exists(file.path(dirs, "config.json"))]
}

runs_table <- function(dirs) {
  empty <- data.frame(
    id = character(), dir = character(), state = character(), stage = character(), method = character(),
    model = character(), created_at = character(), eval_loss = numeric(), stringsAsFactors = FALSE
  )
  if (!length(dirs)) return(empty)
  rows <- lapply(dirs, function(d) {
    cfg <- tryCatch(read_json(file.path(d, "config.json")), error = function(e) NULL)
    st <- tryCatch(read_json(file.path(d, "status.json")), error = function(e) list(state = "unknown"))
    data.frame(
      id = basename(d), dir = normalizePath(d, winslash = "/"),
      state = st$state %||% "unknown",
      stage = cfg$stage %||% "sft",
      method = cfg$prefer$method %||% (if (identical(cfg$stage, "reinforce")) "grpo" else NA_character_),
      model = cfg$model$id %||% NA_character_,
      created_at = cfg$created_at %||% NA_character_,
      eval_loss = as.numeric(st$eval_loss %||% NA_real_),
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, rows)
  out[order(out$created_at, decreasing = TRUE), , drop = FALSE]
}

# Other runs whose config records this one as base_run (chaining), so
# removing it would orphan them.
run_children <- function(id, runs_dir) {
  df <- dragon_runs(runs_dir)
  if (!nrow(df)) return(character())
  hits <- vapply(df$dir, function(d) {
    cfg <- tryCatch(read_json(file.path(d, "config.json")), error = function(e) NULL)
    identical(cfg$model$base_run, id)
  }, logical(1))
  df$id[hits]
}

# Shared guardrails for archive/delete: not currently active, and no other
# run continues from it (unless force = TRUE).
resolve_run_for_removal <- function(run, runs_dir, force) {
  if (is.character(run) && length(run) == 1 && !dir.exists(run)) {
    id <- run
    dir <- file.path(runs_dir, id)
  } else {
    r <- dragon_run(run)
    id <- r$id
    dir <- r$dir
    runs_dir <- dirname(dir)
  }
  if (!dir.exists(dir)) cli::cli_abort("No run at {.path {dir}}.")
  st <- tryCatch(read_json(file.path(dir, "status.json")), error = function(e) list(state = "unknown"))
  if (st$state %in% c("queued", "running")) {
    cli::cli_abort(c("{.strong {id}} is {st$state}.", "i" = "Cancel it first with {.fn dragon_cancel}."))
  }
  if (!isTRUE(force)) {
    kids <- run_children(id, runs_dir)
    if (length(kids)) {
      cli::cli_abort(c(
        "Other runs continue from {.strong {id}}: {.val {kids}}.",
        "i" = "Removing it would orphan them. Pass {.arg force = TRUE} to do it anyway."
      ))
    }
  }
  list(id = id, dir = dir, runs_dir = runs_dir)
}

#' Archive, restore, or delete a run
#'
#' Archiving moves a run's directory under `archived/` in `runs_dir`. It
#' disappears from [dragon_runs()] and the app's Runs list, but every file
#' is kept; [dragon_unarchive_run()] moves it back exactly as it was.
#' Deleting removes the run directory for good. Both refuse a run that is
#' queued or running (cancel it first) and a run that another run
#' continues from, unless `force = TRUE`.
#'
#' @param run A `dragon_run`, run directory, or run id (with `runs_dir`).
#' @param id An archived run's id, for [dragon_unarchive_run()].
#' @param runs_dir Where runs live. Needed only when `run`/`id` is a bare id.
#' @param force Archive or delete even if another run continues from this one.
#' @return The run id, invisibly.
#' @export
#' @examples
#' if (interactive()) {
#' dragon_archive_run(run)
#' dragon_archived_runs()
#' dragon_unarchive_run(run$id)
#' dragon_delete_run("20260101-000000-old-experiment")
#' }
dragon_archive_run <- function(run, runs_dir = dragon_runs_dir(), force = FALSE) {
  info <- resolve_run_for_removal(run, runs_dir, force)
  dest_dir <- file.path(info$runs_dir, "archived")
  dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
  dest <- file.path(dest_dir, info$id)
  if (dir.exists(dest)) cli::cli_abort("An archived run named {.val {info$id}} already exists.")
  if (!file.rename(info$dir, dest)) cli::cli_abort("Could not move {.path {info$dir}} to {.path {dest}}.")
  cli::cli_alert_success("Archived {.strong {info$id}}.")
  invisible(info$id)
}

#' @rdname dragon_archive_run
#' @export
dragon_unarchive_run <- function(id, runs_dir = dragon_runs_dir()) {
  check_string(id, "id")
  src <- file.path(runs_dir, "archived", id)
  if (!dir.exists(src)) cli::cli_abort("No archived run named {.val {id}}.")
  dest <- file.path(runs_dir, id)
  if (dir.exists(dest)) cli::cli_abort("A run named {.val {id}} already exists; rename or delete it first.")
  if (!file.rename(src, dest)) cli::cli_abort("Could not move {.path {src}} to {.path {dest}}.")
  cli::cli_alert_success("Restored {.strong {id}}.")
  invisible(id)
}

#' @rdname dragon_archive_run
#' @export
dragon_delete_run <- function(run, runs_dir = dragon_runs_dir(), force = FALSE) {
  info <- resolve_run_for_removal(run, runs_dir, force)
  unlink(info$dir, recursive = TRUE, force = TRUE)
  cli::cli_alert_success("Deleted {.strong {info$id}}.")
  invisible(info$id)
}

#' @export
print.dragon_run <- function(x, ...) {
  st <- tryCatch(dragon_status(x), error = function(e) list(state = "unknown"))
  cfg <- tryCatch(run_config(x), error = function(e) NULL)
  cli::cli_text("{.cls dragon_run} {.strong {x$id}}")
  cli::cli_text("Directory: {.path {x$dir}}")
  if (!is.null(cfg)) {
    unit <- switch(cfg$data$format %||% "messages", pairs = "pairs", prompts = "prompts", "training rows")
    cli::cli_text("Model: {.val {cfg$model$id}} \u00b7 LoRA r={cfg$lora$r} \u00b7 {cfg$data$n_train} {unit}")
    if (identical(cfg$stage, "prefer")) {
      cli::cli_text("Stage: preference optimization ({toupper(cfg$prefer$method)}, beta {cfg$prefer$beta}){if (!is.null(cfg$model$base_run)) paste0(' \u00b7 continues ', cfg$model$base_run) else ''}")
    } else if (identical(cfg$stage, "reinforce")) {
      cli::cli_text("Stage: reinforcement learning (GRPO, {length(cfg$reinforce$rewards)} reward{?s}, group {cfg$reinforce$group_size}, beta {cfg$reinforce$beta}){if (!is.null(cfg$model$base_run)) paste0(' \u00b7 continues ', cfg$model$base_run) else ''}")
    } else if (!is.null(cfg$model$base_run)) {
      cli::cli_text("Stage: fine-tuning \u00b7 continues {cfg$model$base_run}")
    }
  }
  cli::cli_text("State: {.strong {st$state}}{if (!is.null(st$device)) paste0(' on ', st$device) else ''}")
  pr <- tryCatch(dragon_progress(x), error = function(e) data.frame())
  if (nrow(pr) && "loss" %in% names(pr)) {
    last <- pr[max(which(!is.na(pr$loss))), ]
    cli::cli_text("Progress: step {last$step}{if (!is.null(st$total_steps)) paste0('/', st$total_steps) else ''} \u00b7 loss {round(last$loss, 3)}")
  }
  if (!is.null(st$reward_mean)) {
    cli::cli_text("Held-out reward: {round(st$reward_mean, 3)}")
  } else if (!is.null(st$pref_accuracy)) {
    cli::cli_text("Preference accuracy: {round(100 * st$pref_accuracy)}% \u00b7 reward margin {round(st$reward_margin, 3)} \u00b7 loss {round(st$eval_loss, 3)}")
  } else if (!is.null(st$eval_loss)) {
    cli::cli_text("Eval loss: {round(st$eval_loss, 3)} \u00b7 perplexity {round(st$perplexity, 2)}")
  }
  if (!is.null(st$eval_warning)) cli::cli_text("{.strong Note:} {st$eval_warning}")
  if (!is.null(st$error)) cli::cli_text("{.strong Error:} {error_message(st$error, st$error_code)}")
  invisible(x)
}
