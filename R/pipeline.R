# Recipes: several post-training stages chained in one call, with a record
# on disk so a long pipeline can run in the background and be watched.

new_step <- function(type, ...) structure(list(type = type, ...), class = "dragon_step")

#' Steps of a post-training pipeline
#'
#' Each step becomes one stage of [dragon_pipeline()]. Stages chain: a
#' training step's run is the starting point of the next training step, a
#' synthesis step's pairs feed the next preference step, judge and
#' evaluate steps measure the most recent run, and a merge step writes it
#' out as a standalone model.
#'
#' @param dataset A mapped dataset for the stage. `dragon_step_prefer()`
#'   may leave it `NULL` to use the pairs made by the preceding
#'   `dragon_step_synthesize_pairs()`.
#' @param lora,args,n_samples As in [dragon_train()]. `args = NULL` uses the
#'   stage's own defaults.
#' @param method,beta As in [dragon_prefer()].
#' @param prompts `"train"` or `"eval"` to take prompts from the current run's
#'   data, or a character vector or mapped dataset.
#' @param n How many prompts to use.
#' @param judge,rubric As in [dragon_judge()].
#' @param n_samples_per_prompt,min_gap,temperature,max_new_tokens As in
#'   [dragon_synthesize_pairs()].
#' @param rewards,group_size As in [dragon_reinforce()].
#' @param against As in [dragon_judge()].
#' @param metrics As in [dragon_evaluate()].
#' @param out As `out_dir` in [dragon_merge()]: where the merged model goes;
#'   `NULL` means `merged/` inside the run.
#' @return A `dragon_step` object.
#' @name dragon_step
#' @examples
#' if (interactive()) {
#' steps <- list(
#'   dragon_step_train(tickets),
#'   dragon_step_synthesize_pairs(prompts = "train", n = 150, judge = dragon_judge_anthropic()),
#'   dragon_step_prefer(),
#'   dragon_step_judge(against = "base", judge = dragon_judge_anthropic()),
#'   dragon_step_evaluate(metrics = c("token_f1", "length_ratio"))
#' )
#' p <- dragon_pipeline("Qwen/Qwen2.5-0.5B-Instruct", steps)
#' dragon_compare(p)
#' }
NULL

#' @rdname dragon_step
#' @export
dragon_step_train <- function(dataset, lora = dragon_lora(), args = NULL, n_samples = 10) {
  check_dataset(dataset, mapped = TRUE, kind = "messages")
  new_step("train", dataset = dataset, lora = lora, args = args, n_samples = n_samples)
}

#' @rdname dragon_step
#' @export
dragon_step_prefer <- function(dataset = NULL, method = c("dpo", "orpo"), beta = 0.1, lora = dragon_lora(),
                               args = NULL, n_samples = 10) {
  if (!is.null(dataset)) check_dataset(dataset, mapped = TRUE, kind = "pairs")
  new_step("prefer", dataset = dataset, method = match.arg(method), beta = beta, lora = lora,
           args = args, n_samples = n_samples)
}

#' @rdname dragon_step
#' @export
dragon_step_synthesize_pairs <- function(prompts = "train", n = 100, judge = NULL, n_samples_per_prompt = 4,
                                         min_gap = 2, rubric = NULL, temperature = 0.8, max_new_tokens = 256) {
  if (is.null(judge)) cli::cli_abort("{.fn dragon_step_synthesize_pairs} needs a {.arg judge}.")
  new_step("synthesize_pairs", prompts = prompts, n = n, judge = judge, n_samples = n_samples_per_prompt,
           min_gap = min_gap, rubric = rubric, temperature = temperature, max_new_tokens = max_new_tokens)
}

#' @rdname dragon_step
#' @export
dragon_step_reinforce <- function(dataset, rewards, group_size = 4, beta = 0.04, temperature = 1.0,
                                  max_new_tokens = 128, lora = dragon_lora(), args = NULL, n_samples = 10) {
  check_dataset(dataset, mapped = TRUE, kind = "prompts")
  new_step("reinforce", dataset = dataset, rewards = as_reward_specs(rewards) |> lapply(function(s) structure(s, class = "dragon_reward")),
           group_size = group_size, beta = beta, temperature = temperature, max_new_tokens = max_new_tokens,
           lora = lora, args = args, n_samples = n_samples)
}

#' @rdname dragon_step
#' @export
dragon_step_judge <- function(against = "base", judge = NULL, n = 20, rubric = NULL) {
  if (is.null(judge)) cli::cli_abort("{.fn dragon_step_judge} needs a {.arg judge}.")
  new_step("judge", against = against, judge = judge, n = n, rubric = rubric)
}

#' @rdname dragon_step
#' @export
dragon_step_evaluate <- function(metrics = TRUE) {
  resolve_metrics(metrics)
  new_step("evaluate", metrics = metrics)
}

#' @rdname dragon_step
#' @export
dragon_step_merge <- function(out = NULL) {
  if (!is.null(out)) check_string(out, "out")
  new_step("merge", out = out)
}

#' @rdname dragon_step
#' @param repo,what,private,commit_message As in [dragon_publish()].
#' @export
dragon_step_publish <- function(repo, what = c("merged", "adapter"), private = FALSE, commit_message = NULL) {
  check_string(repo, "repo")
  new_step("publish", repo = repo, what = match.arg(what), private = private, commit_message = commit_message)
}

#' @export
print.dragon_step <- function(x, ...) {
  cli::cli_text("{.cls dragon_step} {.strong {x$type}}")
  invisible(x)
}

check_steps <- function(steps) {
  if (inherits(steps, "dragon_step")) steps <- list(steps)
  if (!is.list(steps) || !length(steps) || !all(vapply(steps, inherits, logical(1), "dragon_step"))) {
    cli::cli_abort("{.arg steps} must be a list of {.fn dragon_step_*} objects.")
  }
  steps
}

pipelines_dir <- function(runs_dir) {
  d <- file.path(runs_dir, "pipelines")
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  d
}

# Run objects carry a live process handle that cannot be serialized.
strip_handles <- function(x) {
  if (inherits(x, "dragon_run")) return(new_run(x$dir))
  if (is.list(x) && !is.data.frame(x)) {
    x[] <- lapply(x, strip_handles)
  }
  x
}

#' Run several post-training stages as one pipeline
#'
#' Executes the steps in order, threading the result of each into the next:
#' every training stage starts from the previous stage's run, synthesized
#' pairs feed the next preference stage, and judge and evaluate steps score
#' the latest run. Progress is written to `pipelines/<id>.json` under
#' `runs_dir` after every step, so a pipeline can be watched from the app or
#' another session with [dragon_pipeline_status()].
#'
#' With `background = TRUE` the pipeline runs in a separate R process and the
#' call returns at once. Steps must then be serializable: judges and
#' teachers made with [dragon_llm_anthropic()] or plain functions are fine,
#' `ellmer` chat objects are not.
#'
#' @param model Where the first training stage starts: a model id, a model
#'   directory, or a finished `dragon_run`.
#' @param steps A list of [dragon_step] objects.
#' @param runs_dir Where runs and the pipeline record are written.
#' @param name Label used in the pipeline id.
#' @param background Run in a separate R process.
#' @return A `dragon_pipeline` object. In the foreground it holds the runs
#'   and every step's summary; in the background it is a handle whose
#'   progress [dragon_pipeline_status()] reads.
#' @export
#' @examples
#' if (interactive()) {
#' p <- dragon_pipeline("Qwen/Qwen2.5-0.5B-Instruct", list(
#'   dragon_step_train(tickets),
#'   dragon_step_synthesize_pairs(judge = dragon_judge_anthropic(model = "claude-sonnet-5")),
#'   dragon_step_prefer(),
#'   dragon_step_judge(judge = dragon_judge_anthropic())
#' ), background = TRUE)
#' dragon_pipeline_status(p)
#' }
dragon_pipeline <- function(model, steps, runs_dir = dragon_runs_dir(), name = "pipeline", background = FALSE) {
  steps <- check_steps(steps)
  if (!inherits(model, "dragon_run")) check_string(model, "model")
  dir.create(runs_dir, recursive = TRUE, showWarnings = FALSE)
  runs_dir <- normalizePath(runs_dir, winslash = "/")
  id <- make_run_id(name)
  record_path <- file.path(pipelines_dir(runs_dir), paste0(id, ".json"))
  record <- list(
    id = id, name = name, created_at = now_iso(), status = "queued", runs_dir = runs_dir,
    model = if (inherits(model, "dragon_run")) model$id else model,
    steps = lapply(steps, function(s) list(type = s$type, state = "queued"))
  )
  write_json(record, record_path)

  if (isTRUE(background)) {
    spec_path <- file.path(pipelines_dir(runs_dir), paste0(id, ".rds"))
    saveRDS(list(model = strip_handles(model), steps = strip_handles(steps), runs_dir = runs_dir, record_path = record_path), spec_path)
    log_path <- file.path(pipelines_dir(runs_dir), paste0(id, ".log"))
    # A script file rather than `Rscript -e`: on Windows, -e writes the code to
    # an "Rscript*" file in the temp folder that is left behind when the
    # process is stopped (a cancelled pipeline).
    script_path <- file.path(pipelines_dir(runs_dir), paste0(id, ".R"))
    writeLines(pipeline_script(spec_path), script_path)
    p <- launch_rscript(script_path, log_path)
    cli::cli_alert_success("Pipeline {.strong {id}} started in the background ({length(steps)} step{?s}).")
    cli::cli_text("Follow it with {.code dragon_pipeline_status(\"{id}\")}; log at {.path {log_path}}.")
    return(structure(list(id = id, path = record_path, log = log_path, process = p, runs_dir = runs_dir),
                     class = "dragon_pipeline"))
  }
  run_pipeline(model, steps, runs_dir, record, record_path)
}

# Run an R script file in a detached background process, output to a log.
launch_rscript <- function(script_path, log_path) {
  processx::process$new(
    file.path(R.home("bin"), "Rscript"), script_path,
    stdout = log_path, stderr = "2>&1", cleanup = FALSE, cleanup_tree = FALSE, windows_hide_window = TRUE
  )
}

# R code the background process runs. Uses the installed package, or the
# development copy when the pipeline was started from load_all().
pipeline_script <- function(spec_path) {
  sprintf("%s; dragonfarm:::run_pipeline_file('%s')", package_loader(), normalizePath(spec_path, winslash = "/", mustWork = FALSE))
}

# How a background R process loads dragonfarm: the installed package, or the
# development copy when this session used load_all().
package_loader <- function() {
  loader <- "suppressPackageStartupMessages(library(dragonfarm))"
  if (requireNamespace("pkgload", quietly = TRUE) && isTRUE(pkgload::is_dev_package("dragonfarm"))) {
    # pkgload::pkg_path() takes a directory, not a package name; the
    # dev-package root is the parent of the shimmed inst/ from system.file().
    root <- tryCatch(dirname(system.file(package = "dragonfarm")), error = function(e) NULL)
    if (!is.null(root) && nzchar(root)) loader <- sprintf("pkgload::load_all('%s', quiet = TRUE)", normalizePath(root, winslash = "/", mustWork = FALSE))
  }
  loader
}

run_pipeline_file <- function(spec_path) {
  spec <- readRDS(spec_path)
  record <- read_json(spec$record_path)
  record$pid <- Sys.getpid()
  invisible(run_pipeline(spec$model, spec$steps, spec$runs_dir, record, spec$record_path))
}

# A cancel request is a file next to the record; the runner looks for it
# between steps and after a step that ended in a cancelled run.
cancel_path <- function(record_path) sub("\\.json$", ".cancel", record_path)
cancel_requested <- function(record_path) file.exists(cancel_path(record_path))

finish_cancelled <- function(record, record_path, i, runs, results, error = NULL) {
  for (j in seq_along(record$steps)) {
    if (j == i && !is.null(error)) {
      record$steps[[j]]$state <- "cancelled"
      record$steps[[j]]$error <- error
      record$steps[[j]]$finished_at <- now_iso()
    } else if (j >= i && !identical(record$steps[[j]]$state, "succeeded")) {
      record$steps[[j]]$state <- "skipped"
    }
  }
  record$status <- "cancelled"
  record$finished_at <- now_iso()
  write_json(record, record_path)
  done <- sum(vapply(record$steps, function(s) identical(s$state, "succeeded"), logical(1)))
  cli::cli_alert_warning("Pipeline {.strong {record$id}} cancelled after {done} of {length(record$steps)} step{?s}.")
  structure(c(record, list(path = record_path, runs = runs, results = results)), class = "dragon_pipeline")
}

run_pipeline <- function(model, steps, runs_dir, record, record_path) {
  state <- list(base = model, run = if (inherits(model, "dragon_run")) model else NULL, pairs = NULL)
  record$status <- "running"
  record$started_at <- now_iso()
  write_json(record, record_path)
  runs <- list()
  results <- list()

  for (i in seq_along(steps)) {
    step <- steps[[i]]
    if (cancel_requested(record_path)) return(finish_cancelled(record, record_path, i, runs, results))
    record$steps[[i]]$state <- "running"
    record$steps[[i]]$started_at <- now_iso()
    write_json(record, record_path)
    cli::cli_h2("Step {i} of {length(steps)}: {step$type}")
    out <- tryCatch(run_step(step, state, runs_dir), error = function(e) e)
    if (inherits(out, "error")) {
      if (cancel_requested(record_path)) return(finish_cancelled(record, record_path, i, runs, results, error = conditionMessage(out)))
      record$steps[[i]]$state <- "failed"
      record$steps[[i]]$error <- conditionMessage(out)
      record$steps[[i]]$finished_at <- now_iso()
      record$status <- "failed"
      record$finished_at <- now_iso()
      write_json(record, record_path)
      cli::cli_abort(c("Pipeline {.strong {record$id}} failed at step {i} ({step$type}).", "x" = "{conditionMessage(out)}"))
    }
    if (!is.null(out$run) && identical(tryCatch(dragon_status(out$run)$state, error = function(e) NULL), "cancelled")) {
      record$steps[[i]]$run <- out$run$id
      return(finish_cancelled(record, record_path, i, c(runs, list(out$run)), results,
                              error = sprintf("Run %s was cancelled.", out$run$id)))
    }
    state <- out$state
    record$steps[[i]]$state <- "succeeded"
    record$steps[[i]]$finished_at <- now_iso()
    record$steps[[i]]$summary <- out$summary
    if (!is.null(out$run)) {
      record$steps[[i]]$run <- out$run$id
      runs[[length(runs) + 1]] <- out$run
    }
    results[[i]] <- out$summary
    write_json(record, record_path)
  }
  record$status <- "succeeded"
  record$finished_at <- now_iso()
  write_json(record, record_path)
  cli::cli_alert_success("Pipeline {.strong {record$id}} finished: {length(runs)} run{?s}.")
  structure(c(record, list(path = record_path, runs = runs, results = results)), class = "dragon_pipeline")
}

run_step <- function(step, state, runs_dir) {
  need_run <- function() {
    if (is.null(state$run)) cli::cli_abort("Step {.val {step$type}} needs a run from an earlier training step.")
    state$run
  }
  switch(step$type,
    train = {
      run <- dragon_train(step$dataset, state$base, lora = step$lora, args = step$args %||% dragon_train_args(),
                          n_samples = step$n_samples, runs_dir = runs_dir, wait = TRUE)
      state$run <- run
      state$base <- run
      list(state = state, run = run, summary = list(run = run$id, eval_loss = dragon_status(run)$eval_loss))
    },
    prefer = {
      ds <- step$dataset %||% state$pairs
      if (is.null(ds)) cli::cli_abort("The preference step has no pairs: give it a dataset or put a {.fn dragon_step_synthesize_pairs} before it.")
      run <- dragon_prefer(ds, state$base, method = step$method, beta = step$beta, lora = step$lora,
                           args = step$args %||% dragon_train_args(learning_rate = 5e-5, epochs = 2),
                           n_samples = step$n_samples, runs_dir = runs_dir, wait = TRUE)
      state$run <- run
      state$base <- run
      st <- dragon_status(run)
      list(state = state, run = run, summary = list(run = run$id, pref_accuracy = st$pref_accuracy, reward_margin = st$reward_margin))
    },
    reinforce = {
      run <- dragon_reinforce(step$dataset, state$base, rewards = step$rewards, group_size = step$group_size,
                              beta = step$beta, temperature = step$temperature, max_new_tokens = step$max_new_tokens,
                              lora = step$lora,
                              args = step$args %||% dragon_train_args(learning_rate = 1e-5, epochs = 1, batch_size = 4, grad_accum = 1, save_steps = 20),
                              n_samples = step$n_samples, runs_dir = runs_dir, wait = TRUE)
      state$run <- run
      state$base <- run
      list(state = state, run = run, summary = list(run = run$id, reward_mean = dragon_status(run)$reward_mean))
    },
    synthesize_pairs = {
      run <- need_run()
      prompts <- step$prompts
      if (is.character(prompts) && length(prompts) == 1 && prompts %in% c("train", "eval")) {
        prompts <- dragon_prompts(run, prompts, n = step$n)
      }
      ds <- dragon_synthesize_pairs(prompts, student = run, judge = step$judge, n_samples = step$n_samples,
                                    min_gap = step$min_gap, rubric = step$rubric, temperature = step$temperature,
                                    max_new_tokens = step$max_new_tokens, runs_dir = runs_dir)
      state$pairs <- ds
      list(state = state, run = NULL, summary = list(pairs = nrow(ds$data), file = ds$source))
    },
    judge = {
      run <- need_run()
      j <- dragon_judge(run, against = step$against, n = step$n, judge = step$judge, rubric = step$rubric)
      list(state = state, run = NULL, summary = c(list(run = run$id, mode = j$mode, against = j$against), j$summary))
    },
    evaluate = {
      run <- need_run()
      ev <- dragon_evaluate(run, metrics = step$metrics)
      list(state = state, run = NULL, summary = list(run = run$id, eval_loss = ev$eval_loss, metrics = as.list(ev$metrics)))
    },
    merge = {
      run <- need_run()
      dir <- dragon_merge(run, step$out)
      list(state = state, run = NULL, summary = list(run = run$id, merged = dir))
    },
    publish = {
      run <- need_run()
      url <- dragon_publish(run, step$repo, what = step$what, private = step$private, commit_message = step$commit_message)
      list(state = state, run = NULL, summary = list(run = run$id, url = url))
    },
    cli::cli_abort("Unknown step type {.val {step$type}}.")
  )
}

#' Progress of a pipeline
#'
#' @param x A `dragon_pipeline` object or a pipeline id.
#' @param runs_dir Where the pipeline record lives, when `x` is an id.
#' @return The pipeline record as a list: `status`, `steps` (each with a
#'   state and, when finished, a summary), and timestamps.
#' @export
dragon_pipeline_status <- function(x, runs_dir = dragon_runs_dir()) {
  path <- pipeline_record_path(x, runs_dir)
  rec <- read_json_retry(path)
  if (inherits(x, "dragon_pipeline") && !is.null(x$process) && rec$status %in% c("queued", "running") && !x$process$is_alive()) {
    rec$status <- "failed"
    rec$error <- paste("The pipeline process exited. Last log lines:", paste(tail_lines(x$log, 20), collapse = "\n"), sep = "\n")
  } else if (rec$status %in% c("queued", "running") && isFALSE(pid_alive(rec$pid))) {
    rec$status <- "failed"
    rec$error <- "The pipeline process is gone."
  }
  structure(rec, class = "dragon_pipeline_status")
}

pipeline_record_path <- function(x, runs_dir) {
  path <- if (inherits(x, "dragon_pipeline")) x$path else file.path(pipelines_dir(runs_dir), paste0(x, ".json"))
  if (!file.exists(path)) cli::cli_abort("No pipeline record at {.path {path}}.")
  path
}

#' Cancel a pipeline
#'
#' Writes a cancel request next to the pipeline record. The runner checks it
#' between steps and stops there. A training step that is under way is asked
#' to stop as well, the way [dragon_cancel()] does, so it saves a checkpoint
#' first; a judging, synthesis, or merge step finishes before the pipeline
#' stops. With `wait = TRUE` the call returns once the pipeline has stopped,
#' killing the pipeline process if it is still going after `timeout` seconds.
#'
#' @param x A `dragon_pipeline` handle or a pipeline id.
#' @param runs_dir Where the pipeline record lives, when `x` is an id.
#' @param wait Wait for the pipeline to stop.
#' @param timeout Seconds to wait before killing the pipeline process.
#' @return The pipeline status, invisibly.
#' @export
dragon_pipeline_cancel <- function(x, runs_dir = dragon_runs_dir(), wait = TRUE, timeout = 120) {
  path <- pipeline_record_path(x, runs_dir)
  rec <- read_json_retry(path)
  if (!rec$status %in% c("queued", "running")) {
    cli::cli_alert_info("Pipeline {.strong {rec$id}} is already {rec$status}.")
    return(invisible(structure(rec, class = "dragon_pipeline_status")))
  }
  writeLines(now_iso(), cancel_path(path))
  for (dir in active_pipeline_runs(rec)) writeLines(now_iso(), file.path(dir, "cancel.request"))
  cli::cli_alert_info("Cancel requested for pipeline {.strong {rec$id}}.")
  if (!isTRUE(wait)) return(invisible(dragon_pipeline_status(x, runs_dir)))
  started <- Sys.time()
  repeat {
    rec <- read_json_retry(path)
    if (!rec$status %in% c("queued", "running") || !pipeline_alive(x, rec)) break
    if (as.numeric(difftime(Sys.time(), started, units = "secs")) > timeout) {
      kill_pipeline_process(x, rec)
      break
    }
    Sys.sleep(1)
  }
  rec <- read_json_retry(path)
  if (rec$status %in% c("queued", "running")) {
    rec$status <- "cancelled"
    rec$finished_at <- now_iso()
    rec$error <- "Stopped by dragon_pipeline_cancel()."
    for (j in seq_along(rec$steps)) {
      st <- rec$steps[[j]]$state
      if (identical(st, "running")) rec$steps[[j]]$state <- "cancelled"
      else if (identical(st, "queued")) rec$steps[[j]]$state <- "skipped"
    }
    write_json(rec, path)
  }
  cli::cli_alert_success("Pipeline {.strong {rec$id}} is {rec$status}.")
  invisible(structure(rec, class = "dragon_pipeline_status"))
}

# Runs this pipeline may be training right now: created after it started
# and still going.
active_pipeline_runs <- function(rec) {
  if (is.null(rec$started_at) || is.null(rec$runs_dir)) return(character())
  df <- dragon_runs(rec$runs_dir)
  keep <- df$state %in% c("queued", "running") & !is.na(df$created_at) & df$created_at >= rec$started_at
  df$dir[keep]
}

pid_alive <- function(pid) {
  if (is.null(pid)) return(NA)
  tryCatch(ps::ps_is_running(ps::ps_handle(as.integer(pid))), error = function(e) FALSE)
}

pipeline_alive <- function(x, rec) {
  if (inherits(x, "dragon_pipeline") && !is.null(x$process)) return(x$process$is_alive())
  alive <- pid_alive(rec$pid)
  if (is.na(alive)) TRUE else alive
}

kill_pipeline_process <- function(x, rec) {
  if (inherits(x, "dragon_pipeline") && !is.null(x$process) && x$process$is_alive()) {
    if (is.function(x$process$kill_tree)) x$process$kill_tree() else x$process$kill()
    return(invisible(TRUE))
  }
  if (!is.null(rec$pid)) {
    h <- tryCatch(ps::ps_handle(as.integer(rec$pid)), error = function(e) NULL)
    if (!is.null(h)) {
      kids <- tryCatch(ps::ps_children(h, recursive = TRUE), error = function(e) list())
      for (k in kids) tryCatch(ps::ps_kill(k), error = function(e) NULL)
      tryCatch(ps::ps_kill(h), error = function(e) NULL)
    }
  }
  invisible(TRUE)
}

#' @export
print.dragon_pipeline_status <- function(x, ...) {
  cli::cli_text("Pipeline {.strong {x$id}}: {.strong {x$status}}")
  for (i in seq_along(x$steps)) {
    s <- x$steps[[i]]
    extra <- if (!is.null(s$run)) paste0(" \u2192 ", s$run)
             else if (!is.null(s$summary$pairs)) paste0(" \u2192 ", s$summary$pairs, " pairs")
             else if (!is.null(s$summary$merged)) paste0(" \u2192 ", s$summary$merged)
             else if (!is.null(s$summary$url)) paste0(" \u2192 ", s$summary$url)
             else ""
    cli::cli_text("  {i}. {s$type}: {s$state}{extra}")
    if (!is.null(s$error)) cli::cli_text("     {.emph {s$error}}")
  }
  invisible(x)
}

#' @export
print.dragon_pipeline <- function(x, ...) {
  if (!is.null(x$process)) {
    print(dragon_pipeline_status(x))
    return(invisible(x))
  }
  cli::cli_text("{.cls dragon_pipeline} {.strong {x$id}}: {x$status}, {length(x$runs)} run{?s}")
  for (i in seq_along(x$steps)) {
    s <- x$steps[[i]]
    cli::cli_text("  {i}. {s$type}: {s$state}{if (!is.null(s$run)) paste0(' \u2192 ', s$run) else ''}")
  }
  invisible(x)
}

# dragon_compare() accepts a finished pipeline: compare its runs.
as_pipeline_runs <- function(x) {
  if (!is.null(x$runs)) return(x$runs)
  rec <- dragon_pipeline_status(x)
  ids <- Filter(Negate(is.null), lapply(rec$steps, function(s) s$run))
  lapply(ids, function(id) dragon_run(file.path(rec$runs_dir, id)))
}
