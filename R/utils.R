# Internal helpers shared across the package.

`%||%` <- function(x, y) if (is.null(x)) y else x

# Package-level mutable state (cached Python path, hardware info).
the <- new.env(parent = emptyenv())

is_windows <- function() .Platform$OS.type == "windows"

now_iso <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

empty_object <- function() structure(list(), names = character(0))

# Sample n indices from seq_len(total), sorted, deterministically for a
# given seed, without disturbing the caller's own RNG stream. Delegates the
# save-and-restore of .Random.seed to withr so dragonfarm's own source never
# touches .GlobalEnv directly.
seeded_sample_idx <- function(total, n, seed) {
  withr::with_seed(seed, sort(sample.int(total, n)))
}

# Appends a line to a run's log file (never the console).
append_log <- function(path, text) {
  con <- file(path, open = "a", encoding = "UTF-8")
  on.exit(close(con))
  writeLines(text, con)
}

read_jsonl <- function(path) {
  if (!file.exists(path)) return(list())
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  lapply(lines, function(l) jsonlite::fromJSON(l, simplifyVector = FALSE))
}

write_jsonl <- function(records, path) {
  lines <- vapply(records, function(r) {
    as.character(jsonlite::toJSON(r, auto_unbox = TRUE, null = "null", digits = NA))
  }, character(1))
  con <- file(path, open = "w", encoding = "UTF-8")
  on.exit(close(con))
  writeLines(lines, con)
  invisible(path)
}

read_json <- function(path) {
  jsonlite::fromJSON(path, simplifyVector = FALSE)
}

# The trainer replaces status.json atomically; a read that lands mid-rename
# can see a missing or partial file, so retry a few times.
read_json_retry <- function(path, attempts = 10) {
  for (i in seq_len(attempts)) {
    out <- tryCatch(read_json(path), error = function(e) NULL)
    if (!is.null(out)) return(out)
    Sys.sleep(0.05 * i)
  }
  read_json(path)
}

write_json <- function(x, path) {
  jsonlite::write_json(x, path, auto_unbox = TRUE, null = "null", pretty = TRUE, digits = NA)
  invisible(path)
}

tail_lines <- function(path, n = 50) {
  if (!file.exists(path)) return(character())
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  utils::tail(lines, n)
}

# Turn a list of flat records (possibly with missing keys) into a data frame.
records_to_df <- function(records) {
  if (!length(records)) return(data.frame())
  cols <- unique(unlist(lapply(records, names)))
  out <- lapply(cols, function(cn) {
    vals <- lapply(records, function(r) {
      v <- r[[cn]]
      if (is.null(v)) return(NA)
      if (is.list(v)) return(as.character(jsonlite::toJSON(v, auto_unbox = TRUE)))
      v
    })
    unlist(vals, use.names = FALSE)
  })
  names(out) <- cols
  as.data.frame(out, stringsAsFactors = FALSE, check.names = FALSE)
}

# Convert literal "\n" typed in a text box into real newlines.
unescape_newlines <- function(x) gsub("\\\\n", "\n", x)
escape_newlines <- function(x) gsub("\n", "\\\\n", x)

check_number <- function(x, arg, min = -Inf, max = Inf, integer = FALSE, allow_null = FALSE) {
  if (is.null(x)) {
    if (allow_null) return(invisible(NULL))
    cli::cli_abort("{.arg {arg}} must not be NULL.")
  }
  if (!is.numeric(x) || length(x) != 1 || is.na(x)) {
    cli::cli_abort("{.arg {arg}} must be a single number.")
  }
  if (integer && x != round(x)) cli::cli_abort("{.arg {arg}} must be a whole number.")
  if (x < min || x > max) cli::cli_abort("{.arg {arg}} must be between {min} and {max}.")
  invisible(x)
}

check_string <- function(x, arg) {
  if (!is.character(x) || length(x) != 1 || is.na(x) || !nzchar(x)) {
    cli::cli_abort("{.arg {arg}} must be a single non-empty string.")
  }
  invisible(x)
}

slugify <- function(x) {
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", "-", x)
  x <- gsub("^-+|-+$", "", x)
  if (!nzchar(x)) "run" else substr(x, 1, 40)
}

# A rough token-count estimate (about 4 characters per token for English),
# used only to warn near a model's context limit and decide when to drop
# the oldest chat turns. Deliberately not a real tokenizer count: getting
# one would mean loading the model's tokenizer in Python for every turn.
estimate_tokens <- function(text) {
  if (is.null(text) || !nzchar(text)) return(0L)
  as.integer(ceiling(nchar(text) / 4))
}

# Signature for a reactivePoll checkFunc: changes whenever any file anywhere
# under a runs directory is added or modified. Watching only each run's own
# status.json mtime missed runs finishing if the last write that mattered
# (the adapter, say) landed a moment after status.json's own mtime was
# already sampled, leaving a run's UI stuck showing stale choices until the
# page was reloaded.
runs_change_signature <- function(dir) {
  # Two levels only: each run, set, or pipeline record, and the files and
  # folders directly inside it (status.json, progress.jsonl, adapter/, ...).
  # Listing everything recursively walked every checkpoint and index file:
  # about a second per call on a thousand files, from seven panels every three
  # seconds, which kept the app busy and let a run-list refresh undo a choice
  # the user had just made. A new or deleted file deeper down still changes
  # its folder's mtime, which is listed.
  top <- list.files(dir, full.names = TRUE)
  if (!length(top)) return("")
  inner <- unlist(lapply(top[dir.exists(top)], list.files, full.names = TRUE), use.names = FALSE)
  files <- sort(c(top, inner))
  # Full paths, not just a count, so a rename (archive/restore moves a run's
  # files to a new path without touching their mtime) changes the signature
  # too, not just an edited file's content would.
  paste(files, file.info(files)$mtime, collapse = "|")
}

hf_token_present <- function() {
  nzchar(Sys.getenv("HF_TOKEN")) || nzchar(Sys.getenv("HUGGING_FACE_HUB_TOKEN")) ||
    file.exists(file.path(Sys.getenv("HF_HOME", file.path(path.expand("~"), ".cache", "huggingface")), "token")) ||
    file.exists(file.path(path.expand("~"), ".cache", "huggingface", "token"))
}

# Deparse a value for generated code; whole numbers print without the L
# suffix that integers read back from JSON would otherwise carry.
fmt_arg <- function(x) {
  if (is.null(x)) return("NULL")
  if (is.numeric(x) && length(x) == 1 && !is.na(x) && x == round(x) && abs(x) < 1e15) return(format(x, scientific = FALSE))
  deparse(x)
}

# Model replies as HTML: Markdown (bold, lists, code) rendered, but nothing
# the model writes can add markup of its own. Raw HTML outside code is
# escaped before rendering, links other than http(s), mailto, and anchors are
# neutralised, and images are dropped (they would load from anywhere).
md_html <- function(text) {
  text <- paste(as.character(text %||% ""), collapse = "\n")
  m <- gregexpr("```[\\s\\S]*?(```|$)|`[^`\n]*`", text, perl = TRUE)
  code <- regmatches(text, m)[[1]]
  other <- gsub("<", "&lt;", regmatches(text, m, invert = TRUE)[[1]], fixed = TRUE)
  safe <- other[1]
  for (i in seq_along(code)) safe <- paste0(safe, code[i], other[i + 1])
  html <- commonmark::markdown_html(safe, extensions = TRUE)
  html <- gsub("href=\"(?!https?://|mailto:|#)[^\"]*\"", "href=\"#\"", html, perl = TRUE)
  html <- gsub("<img[^>]*>", "", html, perl = TRUE)
  shiny::HTML(html)
}

# Hand a file to a Shiny download (U1: modules do not touch files).
copy_for_download <- function(from, to) file.copy(from, to, overwrite = TRUE)
