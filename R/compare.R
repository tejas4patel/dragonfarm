#' Compare runs side by side
#'
#' One row per run with its stage, what it started from, and every number
#' the package knows about it: held-out loss, perplexity, preference
#' accuracy, task metrics from [dragon_evaluate()], and the latest judge
#' result from [dragon_judge()]. Runs that lack a measurement show `NA`.
#'
#' @param ... Runs, run directories, a single `dragon_pipeline` (its runs
#'   are compared), or nothing to list every run in `runs_dir`.
#' @param runs_dir Directory scanned when no runs are given.
#' @return A data frame of class `dragon_comparison`.
#' @export
#' @examples
#' if (interactive()) {
#' dragon_compare()                 # everything in the runs directory
#' ids <- dragon_runs()$id
#' a <- dragon_run(file.path(dragon_runs_dir(), ids[1]))
#' b <- dragon_run(file.path(dragon_runs_dir(), ids[2]))
#' dragon_compare(a, b)             # two specific runs
#' }
dragon_compare <- function(..., runs_dir = dragon_runs_dir()) {
  runs <- list(...)
  if (length(runs) == 1 && inherits(runs[[1]], "dragon_pipeline")) {
    runs <- as_pipeline_runs(runs[[1]])
  } else if (!length(runs)) {
    df <- dragon_runs(runs_dir)
    runs <- lapply(df$dir, dragon_run)
  } else {
    runs <- lapply(runs, dragon_run)
  }
  rows <- lapply(runs, run_summary_row)
  metric_names <- unique(unlist(lapply(rows, function(r) names(r$metrics))))
  out <- do.call(rbind, lapply(rows, function(r) {
    base <- data.frame(
      id = r$id, stage = r$stage, method = r$method, model = r$model, from = r$from, state = r$state,
      n_train = r$n_train, eval_loss = r$eval_loss, perplexity = r$perplexity,
      pref_accuracy = r$pref_accuracy, reward = r$reward, judge = r$judge, judge_n = r$judge_n,
      stringsAsFactors = FALSE
    )
    for (m in metric_names) base[[m]] <- if (!is.null(r$metrics[[m]])) r$metrics[[m]] else NA_real_
    base
  }))
  if (is.null(out)) {
    out <- data.frame(id = character(), stage = character(), method = character(), model = character(),
                      from = character(), state = character(), n_train = integer(), eval_loss = numeric(),
                      perplexity = numeric(), pref_accuracy = numeric(), reward = numeric(), judge = numeric(), judge_n = integer(),
                      stringsAsFactors = FALSE)
  }
  rownames(out) <- NULL
  class(out) <- c("dragon_comparison", class(out))
  out
}

run_summary_row <- function(run) {
  cfg <- run_config(run)
  st <- tryCatch(dragon_status(run), error = function(e) list(state = "unknown"))
  metrics <- st$metrics %||% list()
  judge <- st$judge %||% list()
  judge_value <- judge$win_rate %||% judge$mean_score %||% NA_real_
  list(
    id = run$id,
    stage = cfg$stage %||% "sft",
    method = cfg$prefer$method %||% (if (identical(cfg$stage, "reinforce")) "grpo" else NA_character_),
    model = cfg$model$id %||% NA_character_,
    from = cfg$model$base_run %||% NA_character_,
    state = st$state %||% "unknown",
    n_train = as.integer(cfg$data$n_train %||% NA_integer_),
    eval_loss = as.numeric(st$eval_loss %||% NA_real_),
    perplexity = as.numeric(st$perplexity %||% NA_real_),
    pref_accuracy = as.numeric(st$pref_accuracy %||% NA_real_),
    reward = as.numeric(st$reward_mean %||% NA_real_),
    judge = as.numeric(judge_value),
    judge_n = as.integer(judge$n %||% NA_integer_),
    metrics = lapply(metrics, as.numeric)
  )
}

#' @export
print.dragon_comparison <- function(x, ...) {
  if (!nrow(x)) {
    cli::cli_text("No runs to compare.")
    return(invisible(x))
  }
  df <- as.data.frame(x)
  num <- vapply(df, is.numeric, logical(1))
  df[num] <- lapply(df[num], function(col) ifelse(is.na(col), "", formatC(col, digits = 3, format = "fg")))
  # Columns may have been dropped by subsetting (cmp[, c("id", "state")]).
  if (!is.null(df$model)) df$model <- basename(df$model)
  if (!is.null(df$from)) df$from <- ifelse(is.na(df$from), "", df$from)
  if (!is.null(df$method)) df$method <- ifelse(is.na(df$method), "", df$method)
  keep <- vapply(df, function(col) any(nzchar(as.character(col)) & !is.na(col)), logical(1))
  print(df[, keep, drop = FALSE], row.names = FALSE, right = FALSE)
  invisible(x)
}
