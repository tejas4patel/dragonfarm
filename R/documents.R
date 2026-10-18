#' Read documents into a document set
#'
#' Reads files or web pages, splits them into chunks of about `max_words`
#' words that never cross a heading, and stores the result as a document set
#' under `runs_dir/documents/<name>/`. Each chunk keeps the file (or URL) and
#' the section heading it came from, so later answers can say where they came
#' from. This is the first step of the document route: no column mapping, no
#' training yet.
#'
#' Supported inputs: PDF, HTML, Markdown, plain text, Word (`.docx`),
#' spreadsheets (`.xlsx`, `.csv`, `.tsv`; one chunk per group of rows, each
#' row written as `column: value` pairs), directories (walked for those file
#' types), and `http(s)` URLs (fetched once; the page's text is kept).
#'
#' Reading the same set again re-reads only files whose contents changed and
#' keeps the other chunks as they were. Files named like a changelog
#' (`NEWS`, `CHANGELOG`, ...) or made mostly of version headings are read but
#' flagged, and their chunks are down-weighted when retrieved, because they
#' tend to crowd out the page that actually answers a question. Quoted
#' material (block quotes) and code blocks are marked on each chunk so
#' question generation can skip them.
#'
#' @param paths Character vector of files, directories, or URLs.
#' @param name Name of the document set, used for the directory. Defaults to
#'   the first path's file name, or `"documents"` for several paths.
#' @param runs_dir Parent directory; the set goes under
#'   `file.path(runs_dir, "documents", name)`. See [dragon_runs_dir()] for
#'   why the default is temporary and how to keep sets between sessions.
#' @param max_words Target chunk size in words. Chunks never cross a heading,
#'   so most are shorter.
#' @param min_words Sections shorter than this are folded into the previous
#'   chunk.
#' @param index Build the retrieval index right away (see [dragon_index()]),
#'   so [dragon_ask()] works immediately. The first call downloads the small
#'   embedding model. `FALSE` postpones it; retrieval then indexes on first use.
#' @return A `dragon_documents` object: the directory, the name, and the
#'   manifest. `print()` lists the sources; [dragon_chunks()] returns the
#'   chunks as a data frame.
#' @seealso [dragon_ask()], [dragon_chunks()], [dragon_documents_load()], [dragon_documents_list()]
#' @export
#' @examples
#' if (interactive()) {
#' docs <- dragon_documents(c("policies.pdf", "https://example.com/faq"), name = "support")
#' docs
#' head(dragon_chunks(docs))
#' }
dragon_documents <- function(paths, name = NULL, runs_dir = dragon_runs_dir(),
                             max_words = 170, min_words = 35, index = TRUE) {
  if (!is.character(paths) || !length(paths) || anyNA(paths) || !all(nzchar(paths))) {
    cli::cli_abort("{.arg paths} must be a character vector of files, directories, or URLs.")
  }
  check_number(max_words, "max_words", min = 20, integer = TRUE)
  check_number(min_words, "min_words", min = 1, max = max_words, integer = TRUE)
  local <- paths[!is_url(paths)]
  for (u in paths[is_url(paths)]) outbound_check(u, "fetch a web page as a document", runs_dir = runs_dir)
  missing <- local[!file.exists(local)]
  if (length(missing)) cli::cli_abort("{cli::qty(length(missing))}Path{?s} not found: {.path {missing}}.",
                                       class = "dragonfarm_error", code = "FILE_NOT_FOUND")
  if (is.null(name)) {
    name <- if (length(paths) == 1L) slugify(tools::file_path_sans_ext(basename(paths))) else "documents"
  }
  check_string(name, "name")
  name <- slugify(name)
  dir <- file.path(normalizePath(runs_dir, winslash = "/", mustWork = FALSE), "documents", name)
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)

  abs_paths <- ifelse(is_url(paths), paths, normalizePath(paths, winslash = "/", mustWork = FALSE))
  res <- run_python("dragonfarm.documents", c(
    "build", "--out", dir, "--name", name,
    "--max-words", as.character(as.integer(max_words)), "--min-words", as.character(as.integer(min_words)),
    abs_paths
  ))
  if (res$status != 0) python_failure_message(res, "Reading documents")
  summary <- parse_last_json(res$stdout, "Reading documents")
  for (f in summary$failed) cli::cli_warn("Could not read {.path {f$name}}: {f$error}")
  note <- skipped_note(summary$skipped)
  if (!is.null(note)) cli::cli_alert_info(note)
  if (summary$n_chunks == 0) {
    codes <- vapply(summary$failed, function(f) f$code %||% if (grepl("no text layer", f$error %||% "", fixed = TRUE)) "NO_TEXT_LAYER" else "UNKNOWN", "")
    if (length(codes) && all(codes == "NO_TEXT_LAYER")) {
      cli::cli_abort(c("No text could be read from {.arg paths}: {cli::qty(length(codes))}{?the PDF looks/every PDF looks} scanned (pictures of pages, no text).",
                       "i" = "Run OCR first, for example {.code ocrmypdf in.pdf out.pdf}, and read the result."), class = "dragonfarm_error", code = "NO_TEXT_LAYER")
    }
    cli::cli_abort(c("No text could be read from {.arg paths}.",
                     "i" = "Supported: PDF, HTML, Markdown, text, Word (.docx), .xlsx, .csv, .tsv, and URLs."))
  }
  docs <- dragon_documents_load(dir)
  cli::cli_alert_success(
    "Document set {.strong {name}}: {summary$n_sources} source{?s}, {summary$n_chunks} chunk{?s}{if (summary$n_reused > 0) sprintf(' (%d unchanged)', summary$n_reused) else ''}."
  )
  if (isTRUE(index)) docs <- dragon_index(docs)
  # Record the set's version in the catalogue: a new version whenever its
  # chunks changed. The catalogue never stops a read.
  tryCatch(store_sync_set(store_open(runs_dir), docs$name, docs$dir),
           error = function(e) cli::cli_warn("Could not record the set in the catalogue: {conditionMessage(e)}"))
  docs
}

#' Example documents
#'
#' Three short Markdown files of support policies for a fictional smart-home
#' company (returns and warranty; Wi-Fi, the app, and automations; orders,
#' billing, and support), about a thousand words in all. They pair with
#' [dragon_example_data()]: the example tickets are answered from these
#' policies. Use them to try [dragon_documents()], [dragon_ask()], and
#' [dragon_questions()] before bringing your own files.
#'
#' @return The directory containing the files.
#' @export
#' @examples
#' list.files(dragon_example_documents())
#' if (interactive()) {
#' docs <- dragon_documents(dragon_example_documents(), name = "policies")
#' dragon_ask(docs, "How long is the return window?")
#' }
dragon_example_documents <- function() {
  d <- system.file("extdata", "policies", package = "dragonfarm")
  if (!nzchar(d)) cli::cli_abort("The example documents are missing. Is dragonfarm installed correctly?")
  d
}

#' Reopen a saved document set
#'
#' @param dir The set's directory, as printed by [dragon_documents()], or a
#'   set name under `runs_dir/documents/`.
#' @param runs_dir Where to look when `dir` is a bare name.
#' @return A `dragon_documents` object.
#' @examples
#' if (interactive()) {
#' docs <- dragon_documents(dragon_example_documents(), name = "policies")
#' docs <- dragon_documents_load("policies")
#' docs
#' }
#' @export
dragon_documents_load <- function(dir, runs_dir = dragon_runs_dir()) {
  check_string(dir, "dir")
  if (!dir.exists(dir) && dir.exists(file.path(runs_dir, "documents", dir))) {
    dir <- file.path(runs_dir, "documents", dir)
  }
  manifest_path <- file.path(dir, "manifest.json")
  if (!file.exists(manifest_path)) {
    cli::cli_abort("{.path {dir}} is not a document set (no manifest.json).", class = "dragonfarm_error", code = "NOT_A_SET")
  }
  manifest <- read_json(manifest_path)
  structure(
    list(dir = normalizePath(dir, winslash = "/"), name = manifest$name, manifest = manifest),
    class = "dragon_documents"
  )
}

#' List saved document sets
#'
#' @param runs_dir Parent directory, as for [dragon_documents()].
#' @return A data frame with one row per set: `name`, `sources`, `chunks`,
#'   `indexed`, `updated_at`, `dir`.
#' @examples
#' dragon_documents_list(tempdir())
#' @export
dragon_documents_list <- function(runs_dir = dragon_runs_dir()) {
  root <- file.path(runs_dir, "documents")
  dirs <- if (dir.exists(root)) list.dirs(root, recursive = FALSE) else character()
  dirs <- dirs[file.exists(file.path(dirs, "manifest.json"))]
  rows <- lapply(dirs, function(d) {
    m <- read_json(file.path(d, "manifest.json"))
    data.frame(
      name = m$name %||% basename(d), sources = length(m$sources), chunks = as.integer(m$n_chunks %||% 0L),
      indexed = !is.null(m$index), updated_at = m$updated_at %||% NA_character_,
      dir = normalizePath(d, winslash = "/"), stringsAsFactors = FALSE
    )
  })
  if (!length(rows)) {
    return(data.frame(name = character(), sources = integer(), chunks = integer(), indexed = logical(),
                      updated_at = character(), dir = character(), stringsAsFactors = FALSE))
  }
  out <- do.call(rbind, rows)
  out[order(out$updated_at, decreasing = TRUE), , drop = FALSE]
}

#' The chunks of a document set
#'
#' @param docs A `dragon_documents` object or its directory.
#' @return A data frame with one row per chunk: `id`, `source`, `section`,
#'   `text`, `n_words`, `quoted` (a block quote), `code` (a code block), and
#'   `weight` (0.7 for changelog-like sources, else 1).
#' @examples
#' if (interactive()) {
#' docs <- dragon_documents(dragon_example_documents(), name = "policies")
#' head(dragon_chunks(docs))
#' }
#' @export
dragon_chunks <- function(docs) {
  docs <- as_documents(docs)
  path <- file.path(docs$dir, "chunks.jsonl")
  if (!file.exists(path)) {
    return(data.frame(id = character(), source = character(), section = character(), text = character(),
                      n_words = integer(), quoted = logical(), code = logical(), weight = numeric(),
                      page = integer(), stringsAsFactors = FALSE))
  }
  recs <- read_jsonl(path)
  data.frame(
    id = vapply(recs, function(r) r$id, ""),
    source = vapply(recs, function(r) r$source, ""),
    section = vapply(recs, function(r) r$section %||% "", ""),
    text = vapply(recs, function(r) r$text, ""),
    n_words = vapply(recs, function(r) as.integer(r$n_words), 0L),
    quoted = vapply(recs, function(r) isTRUE(r$quoted), NA),
    code = vapply(recs, function(r) isTRUE(r$code), NA),
    weight = vapply(recs, function(r) as.numeric(r$weight %||% 1), 0),
    page = vapply(recs, function(r) as.integer(r$page %||% NA_integer_), 0L),
    stringsAsFactors = FALSE
  )
}

# "report.pdf, p. 12 \u203a Risk Factors": where an excerpt came from, as
# shown in answers, footnotes, and the excerpt headers of a prompt.
source_label <- function(source, section, page = NA_integer_) {
  page <- rep_len(as.integer(page %||% NA_integer_), length(source))
  section <- rep_len(section %||% "", length(source))
  section[is.na(section)] <- ""
  paste0(source, ifelse(is.na(page), "", paste0(", p. ", page)),
         ifelse(nzchar(section), paste0(" \u203a ", section), ""))
}

as_documents <- function(x) {
  if (inherits(x, "dragon_documents")) return(x)
  if (is.character(x) && length(x) == 1L) return(dragon_documents_load(x))
  cli::cli_abort("Expected a {.cls dragon_documents} object or a document set directory.")
}

#' @export
print.dragon_documents <- function(x, ...) {
  m <- x$manifest
  cli::cli_h3("Document set {.strong {x$name}}")
  cli::cli_text("{.path {x$dir}}")
  srcs <- m$sources
  if (length(srcs)) {
    for (s in srcs) {
      flags <- c(if (isTRUE(s$changelog_like)) "changelog, down-weighted", if (!is.null(s$error)) paste("failed:", s$error))
      flag_txt <- if (length(flags)) paste0(" (", paste(flags, collapse = "; "), ")") else ""
      cli::cli_text("{cli::symbol$bullet} {s$name}: {s$n_chunks} chunk{?s}, {s$n_words} words{flag_txt}")
    }
  }
  cli::cli_text("{m$n_chunks} chunk{?s} of about {m$chunking$max_words} words; index: {if (is.null(m$index)) 'none' else m$index$model}")
  invisible(x)
}

is_url <- function(x) grepl("^https?://", x, ignore.case = TRUE)

# The last line of a Python command's stdout as parsed JSON.
parse_last_json <- function(stdout, what) {
  lines <- strsplit(trimws(stdout), "\n")[[1]]
  lines <- lines[nzchar(trimws(lines))]
  if (!length(lines)) cli::cli_abort("{what} produced no output.")
  tryCatch(jsonlite::fromJSON(lines[length(lines)], simplifyVector = FALSE),
           error = function(e) cli::cli_abort("{what} returned something that is not JSON: {lines[length(lines)]}"))
}

# One line about files a folder held that no reader handles, grouped by type:
# "Skipped 4 files dragonfarm can't read: 2 .png, 1 .doc (save it as .docx),
# 1 .pptx (export it to PDF)." NULL when nothing was skipped.
skipped_note <- function(skipped) {
  if (!length(skipped)) return(NULL)
  ext <- vapply(skipped, function(s) s$ext %||% "(none)", "")
  hint <- vapply(skipped, function(s) s$hint %||% "", "")
  hint <- sub(" and add that$", "", sub(" [(].*[)]", "", hint))
  counts <- sort(table(ext), decreasing = TRUE)
  parts <- vapply(names(counts), function(e) {
    h <- hint[match(e, ext)]
    paste0(counts[[e]], " ", e, if (nzchar(h)) paste0(" (", h, ")") else "")
  }, "")
  sprintf("Skipped %d file%s dragonfarm can't read: %s.", length(skipped), if (length(skipped) == 1) "" else "s",
          paste(parts, collapse = ", "))
}

# Folder of saved document sets, for polling (U1).
documents_signature <- function(runs_dir) runs_change_signature(file.path(runs_dir, "documents"))

# Copy uploaded files (a Shiny fileInput data frame: name, datapath) into the
# set's uploads folder. Returns that folder when it holds any file, else NULL.
documents_stage_uploads <- function(name, files, runs_dir) {
  upload_dir <- file.path(runs_dir, "documents", name, "uploads")
  dir.create(upload_dir, recursive = TRUE, showWarnings = FALSE)
  if (!is.null(files) && nrow(files)) file.copy(files$datapath, file.path(upload_dir, files$name), overwrite = TRUE)
  if (dir.exists(upload_dir) && length(list.files(upload_dir))) upload_dir else NULL
}
