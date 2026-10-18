#' Evaluate a finished run
#'
#' Training already evaluates on the held-out rows and writes the result into
#' the run directory. This function reads that result, or recomputes it with
#' the saved adapter when `recompute = TRUE` or nothing was saved.
#'
#' @param run A `dragon_run` or run directory.
#' @param n_samples Number of held-out prompts to generate replies for. `Inf`
#'   generates for every held-out row.
#' @param recompute Reload the model and evaluate again.
#' @param metrics Task metrics to compute on the generated replies: `TRUE` for
#'   every built-in metric, a character vector of names from
#'   [dragon_metrics()], or a named list of functions. Metrics need a reply
#'   for every held-out row, so replies are generated for all of them when
#'   fewer are on disk. Results are saved to `metrics.json` in the run and
#'   show up in [dragon_compare()].
#' @return A list with `eval_loss`, `perplexity`, `eval_tokens`, and a
#'   `samples` data frame with columns `prompt`, `reference`, `generated`.
#'   Preference runs report `pref_accuracy` (how often the model scores the
#'   chosen reply above the rejected one), `reward_margin`, and `eval_pairs`
#'   instead of perplexity, and their samples also carry `rejected`.
#' @examples
#' if (interactive()) {
#' run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
#' dragon_evaluate(run, n_samples = 5)
#' }
#' @export
dragon_evaluate <- function(run, n_samples = 10, recompute = FALSE, metrics = NULL) {
  run <- dragon_run(run)
  eval_path <- run_path(run, "eval.json")
  samples_path <- run_path(run, "samples.json")
  metric_fns <- resolve_metrics(metrics)
  cfg <- run_config(run)
  n_eval <- cfg$data$n_eval %||% 0L

  # Metrics need a reply for every held-out row.
  if (length(metric_fns)) {
    have <- if (file.exists(samples_path)) length(read_json(samples_path)) else 0L
    if (have < n_eval) {
      n_samples <- Inf
      recompute <- TRUE
    }
  }
  if (recompute || !file.exists(eval_path)) {
    if (!file.exists(run_path(run, "adapter", "adapter_config.json"))) {
      cli::cli_abort("Run {.strong {run$id}} has no saved adapter to evaluate.")
    }
    n_arg <- if (is.infinite(n_samples)) 1000000L else as.integer(n_samples)
    require_gpu_free("Evaluation")
    res <- run_python("dragonfarm.evaluate", c("--run-dir", run$dir, "--n-samples", n_arg))
    if (res$status != 0) python_failure_message(res, "Evaluation")
  }
  stats <- if (file.exists(eval_path)) read_json(eval_path) else list()
  samples <- if (file.exists(samples_path)) read_json(samples_path) else list()
  samples_df <- if (length(samples)) records_to_df(samples) else
    data.frame(prompt = character(), reference = character(), generated = character(), stringsAsFactors = FALSE)

  metric_summary <- NULL
  if (length(metric_fns)) {
    scored <- compute_metrics(samples_df, metric_fns)
    samples_df <- scored$per_sample
    metric_summary <- scored$summary
    write_json(list(computed_at = now_iso(), n = nrow(samples_df), summary = as.list(metric_summary)),
               run_path(run, "metrics.json"))
    st <- read_json(run_path(run, "status.json"))
    st$metrics <- as.list(metric_summary)
    write_json(st, run_path(run, "status.json"))
  } else if (file.exists(run_path(run, "metrics.json"))) {
    metric_summary <- unlist(read_json(run_path(run, "metrics.json"))$summary)
  }

  structure(
    list(
      eval_loss = stats$eval_loss, perplexity = stats$perplexity,
      eval_tokens = stats$eval_tokens,
      pref_accuracy = stats$pref_accuracy, reward_margin = stats$reward_margin,
      eval_pairs = stats$eval_pairs, method = stats$method,
      reward_mean = stats$reward_mean, reward_breakdown = stats$reward_breakdown, eval_prompts = stats$eval_prompts,
      metrics = metric_summary,
      samples = samples_df
    ),
    class = "dragon_eval"
  )
}

#' @export
print.dragon_eval <- function(x, ...) {
  if (!is.null(x$reward_mean)) {
    parts <- if (length(x$reward_breakdown)) paste(sprintf("%s %s", names(x$reward_breakdown), formatC(unlist(x$reward_breakdown), digits = 3, format = "fg")), collapse = " \u00b7 ") else ""
    cli::cli_text("Mean reward {.strong {round(x$reward_mean, 3)}} over {x$eval_prompts} held-out prompt{?s}{if (nzchar(parts)) paste0(' (', parts, ')') else ''}")
  } else if (!is.null(x$pref_accuracy)) {
    cli::cli_text("{toupper(x$method %||% 'preference')} on {x$eval_pairs} held-out pair{?s}: accuracy {.strong {round(100 * x$pref_accuracy)}%} \u00b7 reward margin {.strong {round(x$reward_margin, 3)}} \u00b7 loss {round(x$eval_loss, 4)}")
  } else if (is.null(x$eval_loss)) {
    cli::cli_text("No held-out rows were evaluated for this run.")
  } else {
    cli::cli_text("Eval loss {.strong {round(x$eval_loss, 4)}} \u00b7 perplexity {.strong {round(x$perplexity, 2)}} over {x$eval_tokens} tokens")
  }
  if (length(x$metrics)) {
    parts <- sprintf("%s %s", names(x$metrics), formatC(x$metrics, digits = 3, format = "fg"))
    cli::cli_text("Task metrics over {nrow(x$samples)} repl{?y/ies}: {paste(parts, collapse = ' \u00b7 ')}")
  }
  n <- nrow(x$samples)
  if (n) {
    cli::cli_text("{n} sample generation{?s}. First one:")
    cli::cli_h3("Prompt")
    cli::cli_verbatim(x$samples$prompt[1])
    cli::cli_h3("Generated")
    cli::cli_verbatim(x$samples$generated[1])
    cli::cli_h3("Reference")
    cli::cli_verbatim(x$samples$reference[1])
  }
  invisible(x)
}
