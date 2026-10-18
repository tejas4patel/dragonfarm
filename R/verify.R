# Verify a saved document set: read its files again, with the same chunking,
# into a temporary folder, and compare. A set made from unchanged files by
# the same reader must come back byte for byte; anything else is named (a
# file changed or went missing, the reader is newer) or, if nothing explains
# it, reported as a difference to look into. Web pages are not fetched again
# (that would leave the machine, and pages change); they are listed as not
# checked. The saved set is never touched, and the result is recorded.

documents_verify <- function(set, runs_dir = dragon_runs_dir()) {
  docs <- if (inherits(set, "dragon_documents")) set else dragon_documents_load(set, runs_dir = runs_dir)
  man <- read_json(file.path(docs$dir, "manifest.json"))
  sources <- man$sources %||% list()
  kind <- vapply(sources, function(s) s$kind %||% "file", "")
  files <- sources[kind == "file" & vapply(sources, function(s) is.null(s$error), TRUE)]
  pages <- vapply(sources[kind != "file"], function(s) s$locator %||% "", "")
  locators <- vapply(files, function(s) s$locator, "")
  missing <- locators[!file.exists(locators)]

  out <- list(set = docs$name, verdict = NA_character_, files = length(files), missing = missing, changed = character(),
              not_checked = pages, reader_then = man$chunking$reader, reader_now = NA_integer_, chunks_differ = 0L)
  present <- files[file.exists(locators)]
  if (length(present)) {
    tmp <- tempfile("verify-")
    on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
    again <- suppressMessages(dragon_documents(vapply(present, `[[`, "", "locator"), name = docs$name, runs_dir = tmp,
                                               max_words = man$chunking$max_words %||% 170L,
                                               min_words = man$chunking$min_words %||% 35L, index = FALSE))
    man2 <- read_json(file.path(again$dir, "manifest.json"))
    out$reader_now <- man2$chunking$reader
    then_sha <- stats::setNames(vapply(present, function(s) s$sha256 %||% "", ""), vapply(present, `[[`, "", "locator"))
    now_sha <- stats::setNames(vapply(man2$sources, function(s) s$sha256 %||% "", ""), vapply(man2$sources, `[[`, "", "locator"))
    out$changed <- names(then_sha)[then_sha != now_sha[names(then_sha)]]
    # Compare the chunks of the files, line by line, by source.
    ids <- unique(vapply(read_jsonl(file.path(again$dir, "chunks.jsonl")), `[[`, "", "source_id"))
    keep <- function(path) {
      lines <- readLines(path, encoding = "UTF-8", warn = FALSE)
      lines[vapply(lines, function(l) jsonlite::fromJSON(l)$source_id %in% ids, TRUE)]
    }
    a <- keep(file.path(docs$dir, "chunks.jsonl"))
    b <- readLines(file.path(again$dir, "chunks.jsonl"), encoding = "UTF-8", warn = FALSE)
    out$chunks_differ <- as.integer(length(setdiff(a, b)) + length(setdiff(b, a)))
  }
  out$verdict <- if (!length(present)) "nothing to check"
    else if (out$chunks_differ == 0L && !length(missing)) "identical"
    else if (length(missing) || length(out$changed)) "sources changed"
    else if (!identical(as.integer(out$reader_then %||% NA), as.integer(out$reader_now))) "reader changed"
    else "differs"
  store_record_event("verify", docs$name, ok = identical(out$verdict, "identical"),
                     code = if (identical(out$verdict, "differs")) "UNKNOWN",
                     detail = out[c("verdict", "files", "missing", "changed", "not_checked", "reader_then", "reader_now", "chunks_differ")],
                     runs_dir = runs_dir)
  out
}
