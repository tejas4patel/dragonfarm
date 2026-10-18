#' Create a dataset for fine-tuning
#'
#' Reads a file or wraps a data frame. Use [dragon_map()] afterwards to say
#' which columns hold the prompt and the response.
#'
#' @param x A file path (CSV, TSV, JSONL, JSON array, or Parquet) or a data frame.
#' @param ... Passed to methods.
#' @return A `dragon_dataset` object.
#' @export
#' @examples
#' ds <- dragon_dataset(dragon_example_data())
#' ds
dragon_dataset <- function(x, ...) UseMethod("dragon_dataset")

#' @rdname dragon_dataset
#' @param format One of `"csv"`, `"tsv"`, `"jsonl"`, `"json"`, or `"parquet"`.
#'   Inferred from the file extension when `NULL`.
#' @param name Display name. Defaults to the file name.
#' @export
dragon_dataset.character <- function(x, format = NULL, name = NULL, ...) {
  if (length(x) != 1 || !file.exists(x)) cli::cli_abort("File {.path {x}} does not exist.")
  format <- tolower(format %||% tools::file_ext(x))
  df <- switch(format,
    csv = utils::read.csv(x, stringsAsFactors = FALSE, check.names = FALSE,
                          fileEncoding = "UTF-8-BOM", na.strings = c("NA", "")),
    tsv = utils::read.delim(x, stringsAsFactors = FALSE, check.names = FALSE,
                            fileEncoding = "UTF-8-BOM", na.strings = c("NA", "")),
    jsonl = ,
    ndjson = records_to_df(read_jsonl(x)),
    json = as.data.frame(jsonlite::fromJSON(x, simplifyVector = TRUE),
                         stringsAsFactors = FALSE, check.names = FALSE),
    parquet = {
      rlang::check_installed("arrow", reason = "to read Parquet files.")
      as.data.frame(arrow::read_parquet(x))
    },
    cli::cli_abort("Unsupported format {.val {format}}. Use csv, tsv, jsonl, json, or parquet.")
  )
  new_dataset(df, source = x, name = name %||% basename(x))
}

#' @rdname dragon_dataset
#' @export
dragon_dataset.data.frame <- function(x, name = NULL, ...) {
  new_dataset(x, source = "data.frame", name = name %||% deparse(substitute(x))[1])
}

new_dataset <- function(df, source, name) {
  df <- as.data.frame(df, stringsAsFactors = FALSE, check.names = FALSE)
  if (!ncol(df)) cli::cli_abort("The dataset has no columns.")
  if (!nrow(df)) cli::cli_abort("The dataset has no rows.")
  df[] <- lapply(df, function(col) if (is.factor(col)) as.character(col) else col)
  rownames(df) <- NULL
  structure(
    list(data = df, source = source, name = name, mapping = NULL, split = NULL),
    class = "dragon_dataset"
  )
}

#' @export
print.dragon_dataset <- function(x, ...) {
  cli::cli_text("{.cls dragon_dataset} {.strong {x$name}}: {nrow(x$data)} row{?s}, {ncol(x$data)} column{?s}")
  types <- vapply(x$data, function(col) class(col)[1], character(1))
  cli::cli_text("Columns: {paste0(names(types), ' <', types, '>', collapse = ', ')}")
  if (is.null(x$mapping)) {
    cli::cli_text("Mapping: {.emph none yet}. Call {.fn dragon_map}.")
  } else {
    m <- x$mapping
    if (identical(m$kind, "conversations")) {
      cli::cli_text("Whole conversations: {nrow(x$data)}, {round(mean(x$data$turns), 1)} turns on average. The final assistant turn is the target.")
      if (!is.null(x$split)) cli::cli_text("Split: {length(x$split$eval_idx)} evaluation row{?s} (seed {x$split$seed})")
      return(invisible(x))
    }
    cli::cli_text("Prompt: {.val {escape_newlines(m$prompt)}}")
    if (identical(m$kind, "pairs")) {
      cli::cli_text("Chosen: {.val {escape_newlines(m$chosen)}}")
      cli::cli_text("Rejected: {.val {escape_newlines(m$rejected)}}")
    } else if (identical(m$kind, "prompts")) {
      cli::cli_text("Reference: {if (is.null(m$reference)) 'none' else escape_newlines(m$reference)} (RL prompts)")
    } else {
      cli::cli_text("Response: {.val {escape_newlines(m$response)}}")
    }
    if (!is.null(m$system)) cli::cli_text("System: {.val {escape_newlines(m$system)}}")
  }
  if (!is.null(x$split)) {
    cli::cli_text("Split: {length(x$split$eval_idx)} evaluation row{?s} (seed {x$split$seed})")
  }
  invisible(x)
}

#' Path to the bundled example dataset
#'
#' Two hundred synthetic customer-support tickets with `subject`, `body`,
#' `product`, and `reply` columns. Small enough to train on a CPU in minutes.
#'
#' @return A file path.
#' @export
#' @examples
#' dragon_example_data()
dragon_example_data <- function() {
  system.file("extdata", "support_tickets.jsonl", package = "dragonfarm")
}

# TRUE when the first non-empty line of a JSONL file is an object with a
# "messages" list (the chat format).
looks_like_conversations <- function(path) {
  con <- file(path, open = "r", encoding = "UTF-8")
  on.exit(close(con))
  repeat {
    line <- readLines(con, n = 1, warn = FALSE)
    if (!length(line)) return(FALSE)
    if (nzchar(trimws(line))) break
  }
  x <- tryCatch(jsonlite::fromJSON(line, simplifyVector = FALSE), error = function(e) NULL)
  is.list(x) && is.list(x$messages) && length(x$messages) > 0
}
