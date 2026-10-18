#' Map dataset columns to prompt, response, and system text
#'
#' Each argument is either a column name or a [glue::glue()] template that
#' combines several columns, such as `"{subject}\n\n{body}"`. Templates are
#' rendered per row when the training files are written.
#'
#' @param dataset A `dragon_dataset`.
#' @param prompt Column name or template for the user turn.
#' @param response Column name or template for the assistant turn.
#' @param system Optional column name or template for the system prompt. A
#'   template with no braces and no matching column is used as a constant
#'   system prompt for every row.
#' @return The dataset with the mapping attached.
#' @export
#' @examples
#' ds <- dragon_dataset(dragon_example_data())
#' ds <- dragon_map(ds, prompt = "{subject}\n\n{body}", response = "reply")
#' dragon_preview(ds, n = 1)
dragon_map <- function(dataset, prompt, response, system = NULL) {
  check_dataset(dataset)
  cols <- names(dataset$data)
  dataset$mapping <- list(
    kind = "messages",
    prompt = as_template(prompt, cols, "prompt"),
    response = as_template(response, cols, "response"),
    system = if (!is.null(system)) as_template(system, cols, "system", allow_constant = TRUE)
  )
  dataset
}

check_dataset <- function(dataset, mapped = FALSE, kind = NULL) {
  if (is.null(dataset)) {
    cli::cli_abort("{.arg dataset} is NULL: there is nothing to train on yet.")
  }
  if (!inherits(dataset, "dragon_dataset")) {
    cli::cli_abort("{.arg dataset} must be created with {.fn dragon_dataset}.")
  }
  if ((mapped || !is.null(kind)) && is.null(dataset$mapping)) {
    cli::cli_abort("The dataset has no column mapping. Call {.fn dragon_map} first, or {.fn dragon_map_pairs} for preference pairs.")
  }
  have <- mapping_kind(dataset)
  # Whole conversations train the same way as prompt/response rows.
  if (identical(kind, "messages") && identical(have, "conversations")) kind <- "conversations"
  if (!is.null(kind) && !identical(have, kind)) {
    mappers <- c(messages = "dragon_map", pairs = "dragon_map_pairs", prompts = "dragon_map_prompts", conversations = "dragon_conversations")
    stages <- c(messages = "dragon_train", pairs = "dragon_prefer", prompts = "dragon_reinforce", conversations = "dragon_train")
    labels <- c(messages = "prompt and response rows", pairs = "preference pairs", prompts = "RL prompts", conversations = "conversations")
    cli::cli_abort(c(
      "This dataset is mapped as {labels[[have]]}, but this step needs {labels[[kind]]}.",
      "i" = "Use {.fn {stages[[have]]}} with this mapping, or map the dataset again with {.fn {mappers[[kind]]}}."
    ))
  }
  invisible(dataset)
}

as_template <- function(x, cols, arg, allow_constant = FALSE) {
  check_string(x, arg)
  if (!grepl("{", x, fixed = TRUE)) {
    if (x %in% cols) return(paste0("{`", x, "`}"))
    if (allow_constant) return(x)
    cli::cli_abort(c(
      "Column {.val {x}} for {.arg {arg}} was not found.",
      "i" = "Available columns: {.val {cols}}."
    ))
  }
  vars <- template_vars(x)
  missing <- setdiff(vars, cols)
  if (length(missing)) {
    cli::cli_abort(c(
      "Template for {.arg {arg}} refers to column{?s} {.val {missing}} that do{?es/} not exist.",
      "i" = "Available columns: {.val {cols}}."
    ))
  }
  x
}

# Column names referenced inside {braces}. Backticks are stripped.
template_vars <- function(tpl) {
  m <- regmatches(tpl, gregexpr("\\{[^{}]+\\}", tpl))[[1]]
  vars <- gsub("^\\{|\\}$", "", m)
  unique(trimws(gsub("`", "", vars)))
}

render_template <- function(tpl, data) {
  if (!grepl("{", tpl, fixed = TRUE)) return(rep(tpl, nrow(data)))
  # Wrap bare column names in backticks so names with spaces work.
  vars <- template_vars(tpl)
  for (v in vars) {
    tpl <- gsub(paste0("\\{\\s*`?", gsub("([.|()\\^{}+$*?\\[\\]\\\\])", "\\\\\\1", v), "`?\\s*\\}"),
                paste0("{`", v, "`}"), tpl)
  }
  out <- glue::glue_data(data, tpl, .na = "", .null = "")
  as.character(out)
}

# Build the chat messages for rows `idx` (all rows when NULL).
dataset_messages <- function(dataset, idx = NULL) {
  check_dataset(dataset, mapped = TRUE)
  d <- dataset$data
  if (!is.null(idx)) d <- d[idx, , drop = FALSE]
  if (!nrow(d)) return(list())
  m <- dataset$mapping
  prompt <- render_template(m$prompt, d)
  response <- render_template(m$response, d)
  system <- if (!is.null(m$system)) render_template(m$system, d)
  lapply(seq_len(nrow(d)), function(i) {
    msgs <- list()
    if (!is.null(system) && nzchar(trimws(system[i]))) {
      msgs[[length(msgs) + 1]] <- list(role = "system", content = system[i])
    }
    msgs[[length(msgs) + 1]] <- list(role = "user", content = prompt[i])
    msgs[[length(msgs) + 1]] <- list(role = "assistant", content = response[i])
    list(messages = msgs)
  })
}

#' Preview mapped rows as chat turns
#'
#' @param dataset A mapped `dragon_dataset`.
#' @param n Number of rows to show.
#' @return Invisibly, a list of message lists.
#' @examples
#' ds <- dragon_map(dragon_dataset(dragon_example_data()),
#'                  prompt = "{subject}\n\n{body}", response = "reply")
#' dragon_preview(ds, n = 2)
#' @export
dragon_preview <- function(dataset, n = 3) {
  check_dataset(dataset, mapped = TRUE)
  idx <- seq_len(min(n, nrow(dataset$data)))
  rows <- preview_rows(dataset, idx)
  for (i in seq_along(rows)) {
    cli::cli_h3("Row {idx[i]}")
    for (msg in rows[[i]]$messages) {
      cli::cli_text("{.strong {msg$role}}:")
      cli::cli_verbatim(msg$content)
    }
  }
  invisible(rows)
}

#' Hold out rows for evaluation
#'
#' If you do not call this, [dragon_train()] holds out 5 percent of rows
#' (and none when the dataset has fewer than 20 rows).
#'
#' @param dataset A `dragon_dataset`.
#' @param eval_frac Fraction of rows to hold out.
#' @param seed Random seed for the split.
#' @return The dataset with the split attached.
#' @examples
#' ds <- dragon_map(dragon_dataset(dragon_example_data()),
#'                  prompt = "{subject}\n\n{body}", response = "reply")
#' ds <- dragon_split(ds, eval_frac = 0.1)
#' ds$split
#' @export
dragon_split <- function(dataset, eval_frac = 0.05, seed = 42) {
  check_dataset(dataset)
  check_number(eval_frac, "eval_frac", min = 0, max = 0.5)
  n <- nrow(dataset$data)
  n_eval <- floor(n * eval_frac)
  eval_idx <- integer()
  if (n_eval > 0) {
    eval_idx <- seeded_sample_idx(n, n_eval, seed)
  }
  dataset$split <- list(eval_frac = eval_frac, seed = seed, eval_idx = eval_idx)
  dataset
}

# Write data/train.jsonl and data/eval.jsonl under `dir`.
write_dataset_files <- function(dataset, dir) {
  check_dataset(dataset, mapped = TRUE)
  if (is.null(dataset$split)) dataset <- dragon_split(dataset)
  n <- nrow(dataset$data)
  eval_idx <- dataset$split$eval_idx
  train_idx <- setdiff(seq_len(n), eval_idx)
  data_dir <- file.path(dir, "data")
  dir.create(data_dir, recursive = TRUE, showWarnings = FALSE)
  write_jsonl(dataset_rows(dataset, train_idx), file.path(data_dir, "train.jsonl"))
  has_eval <- length(eval_idx) > 0
  if (has_eval) write_jsonl(dataset_rows(dataset, eval_idx), file.path(data_dir, "eval.jsonl"))
  list(
    train = "data/train.jsonl",
    eval = if (has_eval) "data/eval.jsonl" else NULL,
    n_train = length(train_idx),
    n_eval = length(eval_idx),
    # Conversations are written as the same {"messages": [...]} rows the trainer already reads.
    format = if (identical(mapping_kind(dataset), "conversations")) "messages" else mapping_kind(dataset)
  )
}
