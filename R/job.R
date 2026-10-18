#' Inspect a run
#'
#' `dragon_status()` reads the run's state. `dragon_progress()` returns one
#' row per logged step. `dragon_logs()` returns the tail of the trainer log.
#'
#' @param run A `dragon_run`.
#' @return `dragon_status()`: a list with at least `state`, one of
#'   `"queued"`, `"running"`, `"succeeded"`, `"failed"`, `"cancelled"`.
#' @export
dragon_status <- function(run) {
  check_run(run)
  path <- run_path(run, "status.json")
  st <- if (file.exists(path)) read_json_retry(path) else list(state = "unknown")
  if (st$state %in% c("queued", "running") && !process_alive(run, st)) {
    st$state <- "failed"
    st$finished_at <- now_iso()
    code <- if (!is.null(run$process)) tryCatch(run$process$get_exit_status(), error = function(e) NA) else NA
    st$exit_status <- code
    st$error <- paste0(
      "The trainer process exited without reporting a result",
      if (!is.na(code)) sprintf(" (exit status %s)", format(code)) else "",
      ". Last log lines:\n",
      paste(tail_lines(run_path(run, "log.txt"), 30), collapse = "\n")
    )
    write_json(st, path)
  }
  st
}

process_alive <- function(run, st) {
  if (!is.null(run$process)) return(run$process$is_alive())
  pid <- st$pid
  if (is.null(pid)) {
    # Queued but no pid yet. Give the interpreter a grace period to start.
    age <- as.numeric(difftime(Sys.time(), file.info(run_path(run, "status.json"))$mtime, units = "mins"))
    return(is.na(age) || age < 10)
  }
  tryCatch(ps::ps_is_running(ps::ps_handle(as.integer(pid))), error = function(e) FALSE)
}

progress_cols <- c("step", "epoch", "loss", "eval_loss", "lr", "grad_norm", "elapsed_s", "eta_s",
                   "pref_acc", "reward_margin", "eval_pref_acc", "eval_reward_margin",
                   "reward", "reward_std", "kl", "completion_len")

dragon_progress_empty <- function() {
  as.data.frame(stats::setNames(replicate(length(progress_cols), numeric(), simplify = FALSE), progress_cols))
}

#' @rdname dragon_status
#' @return `dragon_progress()`: a data frame with columns `step`, `epoch`,
#'   `loss`, `eval_loss`, `lr`, `grad_norm`, `elapsed_s`, `eta_s`, and for
#'   preference runs `pref_acc`, `reward_margin`, `eval_pref_acc`,
#'   `eval_reward_margin`.
#' @export
dragon_progress <- function(run) {
  check_run(run)
  rows <- read_jsonl(run_path(run, "progress.jsonl"))
  cols <- progress_cols
  if (!length(rows)) return(dragon_progress_empty())
  df <- records_to_df(rows)
  for (cn in setdiff(cols, names(df))) df[[cn]] <- NA_real_
  extra <- setdiff(names(df), cols)          # per-reward columns such as reward_numeric
  df <- df[, c(cols, extra), drop = FALSE]
  df[] <- lapply(df, as.numeric)
  df
}

#' @rdname dragon_status
#' @param n Number of log lines to return.
#' @return `dragon_logs()`: a character vector.
#' @export
dragon_logs <- function(run, n = 50) {
  check_run(run)
  tail_lines(run_path(run, "log.txt"), n)
}

#' Wait for a run to finish
#'
#' Blocks with a progress bar until the run reaches a terminal state.
#'
#' @param run A `dragon_run`.
#' @param timeout Seconds to wait before giving up (the run keeps going).
#' @param poll Seconds between checks.
#' @return The run, invisibly. Errors if the run failed.
#' @export
dragon_wait <- function(run, timeout = Inf, poll = 2) {
  check_run(run)
  if (identical(dragon_status(run)$state, "bundled")) {
    cli::cli_abort(c(
      "Run {.strong {run$id}} was bundled for a cloud GPU and has not been trained here.",
      "i" = "Train it with {.fn dragon_remote}, then bring the outputs back with {.fn dragon_import}."
    ))
  }
  started <- Sys.time()
  bar <- NULL
  total_known <- FALSE
  repeat {
    st <- dragon_status(run)
    pr <- dragon_progress(run)
    total <- st$total_steps
    if (!total_known && !is.null(total) && total > 0) {
      cli::cli_progress_done(id = bar)
      bar <- cli::cli_progress_bar("Training", total = total, clear = FALSE, auto_terminate = FALSE, .envir = environment())
      total_known <- TRUE
    } else if (is.null(bar)) {
      bar <- cli::cli_progress_bar("Starting trainer (loading model)", total = NA, clear = FALSE, auto_terminate = FALSE, .envir = environment())
    }
    # The bar is decoration: a rendering problem (narrow console, odd width
    # arithmetic in the terminal) must never end the wait.
    try({
      if (nrow(pr)) {
        lossrows <- pr[!is.na(pr$loss), , drop = FALSE]
        status_txt <- if (nrow(lossrows)) sprintf("loss %.3f", utils::tail(lossrows$loss, 1)) else ""
        if ("reward" %in% names(pr) && any(!is.na(pr$reward))) {
          status_txt <- sprintf("reward %.3f", utils::tail(pr$reward[!is.na(pr$reward)], 1))
        }
        step <- max(pr$step, na.rm = TRUE)
        if (total_known) cli::cli_progress_update(id = bar, set = min(step, total), status = status_txt, .envir = environment())
        else cli::cli_progress_update(id = bar, status = status_txt, .envir = environment())
      } else {
        cli::cli_progress_update(id = bar, .envir = environment())
      }
    }, silent = TRUE)
    if (st$state %in% c("succeeded", "failed", "cancelled")) break
    if (as.numeric(difftime(Sys.time(), started, units = "secs")) > timeout) {
      cli::cli_progress_done(id = bar)
      cli::cli_alert_warning("Timed out waiting; the run is still {st$state}.")
      return(invisible(run))
    }
    Sys.sleep(poll)
  }
  cli::cli_progress_done(id = bar)
  if (st$state == "failed") {
    # The error text comes from the trainer log and may contain braces; pass it
    # as a value so cli does not try to interpolate it.
    err <- error_message(st$error %||% "unknown error", st$error_code)
    cli::cli_abort(c("Run {.strong {run$id}} failed.", "x" = "{err}"))
  }
  if (st$state == "cancelled") {
    cli::cli_alert_warning("Run {.strong {run$id}} was cancelled. The adapter holds the last checkpoint.")
  } else {
    msg <- "Run {.strong {run$id}} succeeded."
    if (!is.null(st$reward_mean)) {
      msg <- paste0(msg, " Mean reward on held-out prompts {round(st$reward_mean, 3)}.")
    } else if (!is.null(st$pref_accuracy)) {
      msg <- paste0(msg, " Preference accuracy {round(100 * st$pref_accuracy)}%, reward margin {round(st$reward_margin, 3)}.")
    } else if (!is.null(st$eval_loss) && !is.null(st$perplexity)) {
      msg <- paste0(msg, " Eval loss {round(st$eval_loss, 3)}, perplexity {round(st$perplexity, 2)}.")
    }
    cli::cli_alert_success(msg)
  }
  invisible(run)
}

#' Cancel a run
#'
#' Asks the trainer to stop after the current step and save a checkpoint.
#' Falls back to killing the process if it does not stop in time.
#'
#' @param run A `dragon_run`.
#' @param timeout Seconds to wait for a clean stop.
#' @return The run, invisibly.
#' @export
dragon_cancel <- function(run, timeout = 120) {
  check_run(run)
  st <- dragon_status(run)
  if (!st$state %in% c("queued", "running")) {
    cli::cli_alert_info("Run is already {st$state}.")
    return(invisible(run))
  }
  writeLines(now_iso(), run_path(run, "cancel.request"))
  cli::cli_alert_info("Cancel requested; waiting for the trainer to save a checkpoint.")
  started <- Sys.time()
  repeat {
    st <- dragon_status(run)
    if (!st$state %in% c("queued", "running")) break
    if (as.numeric(difftime(Sys.time(), started, units = "secs")) > timeout) {
      kill_run_process(run, st)
      st$state <- "cancelled"
      st$finished_at <- now_iso()
      st$error <- "Killed after cancel timeout."
      write_json(st, run_path(run, "status.json"))
      break
    }
    Sys.sleep(1)
  }
  cli::cli_alert_success("Run {.strong {run$id}} is {st$state}.")
  invisible(run)
}

kill_run_process <- function(run, st) {
  if (!is.null(run$process) && run$process$is_alive()) {
    run$process$kill()
    return(invisible(TRUE))
  }
  if (!is.null(st$pid)) {
    tryCatch(ps::ps_kill(ps::ps_handle(as.integer(st$pid))), error = function(e) NULL)
  }
  invisible(TRUE)
}

# A run that says "running" but has stopped moving: the process is alive but
# the last progress line is older than 15 minutes or five of its usual gaps
# between progress lines, whichever is longer (30 minutes before the first
# line, which covers loading a large model). A laptop that sleeps stalls GPU
# jobs this way. Returns the minutes since the last sign of life, or NULL.
run_stalled <- function(run, st, now = Sys.time()) {
  if (!identical(st$state, "running")) return(NULL)
  prog <- run_path(run, "progress.jsonl")
  rows <- if (file.exists(prog)) read_jsonl(prog) else list()
  last <- if (length(rows)) file.info(prog)$mtime else file.info(run_path(run, "status.json"))$mtime
  if (is.na(last)) return(NULL)
  idle <- as.numeric(difftime(now, last, units = "mins"))
  limit <- if (length(rows) >= 2) {
    el <- vapply(rows, function(r) as.numeric(r$elapsed_s %||% NA), 0)
    gap <- stats::median(diff(el[!is.na(el)]), na.rm = TRUE) / 60
    max(15, 5 * if (is.finite(gap)) gap else 0)
  } else if (length(rows)) 15 else 30
  if (idle > limit) round(idle) else NULL
}

# Disk space: a run's folder (adapter, data, merged copy if any), and all
# runs together with the largest first, so a person can decide what to
# archive or delete (both stay a person's choice).
dir_bytes <- function(dir) {
  f <- list.files(dir, recursive = TRUE, full.names = TRUE, all.files = TRUE)
  sum(file.info(f)$size, na.rm = TRUE)
}

runs_space <- function(runs) {
  if (!nrow(runs)) return(data.frame(id = character(), bytes = numeric()))
  out <- data.frame(id = runs$id, bytes = vapply(runs$dir, dir_bytes, 0, USE.NAMES = FALSE))
  out[order(-out$bytes), , drop = FALSE]
}

fmt_bytes <- function(b) format(structure(b, class = "object_size"), units = "auto", standard = "SI")
