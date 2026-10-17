#' Write questions and answers from a document set
#'
#' Turns documents into training data. For each chunk a model writes a few
#' self-contained questions and answers them from that chunk alone; simple
#' deterministic filters then mark pairs that are not grounded in the chunk,
#' name things the chunk does not, refer to "the passage", or duplicate
#' another question. Nothing is dropped: every pair comes back with `keep`
#' and, when rejected, a `reason`, so you can review them (the Documents tab
#' has a screen for it) before training with [dragon_questions_dataset()].
#'
#' Review them. On the package's own documentation about 60 percent of a
#' 7B model's pairs were usable, 33 percent of a 3B's, 20 percent of a
#' 1.5B's, and a fifth of what passed the filters was still wrong or trivial.
#' Quoted material and changelog-like sources are skipped by default because
#' they produced the worst pairs.
#'
#' @param docs A `dragon_documents` object or its directory.
#' @param generator What writes the pairs. `NULL` uses the local model
#'   recommended for this machine (see [dragon_check()]); a model id uses
#'   that local model; a teacher such as [dragon_llm_anthropic()], an
#'   `ellmer` chat, a run, or any function from prompts to replies is called
#'   from R instead. Local generation runs as a background Python process.
#' @param n_per_chunk Questions asked for per chunk.
#' @param mix Ask for a mix of question types: one "what" or "which", one
#'   "why" or "how", and, where the passage compares two things, one "how do
#'   they differ". On FDA guidance this raised comparison questions from 11
#'   to 98 of the kept pairs and why/how questions from 113 to 142, kept 81
#'   percent of pairs instead of 89, and a 3B trained on either set answered
#'   the same 23 of 24 test questions. `FALSE` asks for any three questions.
#' @param include_quotes,include_code,include_changelog Which chunks to use.
#'   Block quotes are skipped by default (a quoted example reply is not your
#'   policy), code blocks are included, changelog-like sources are skipped.
#' @param load_in_4bit For a local generator: `"auto"`, `TRUE`, or `FALSE`;
#'   see [dragon_backend_local()].
#' @param batch_size,max_new_tokens Local generation settings.
#' @param wait Block until done. With `FALSE`, a local generation returns a
#'   job to poll with [dragon_questions_progress()] and finish with
#'   [dragon_questions_wait()]; a teacher always runs to completion.
#' @return A `dragon_questions` data frame: `id`, `chunk_id`, `source`,
#'   `section`, `question`, `answer`, `keep`, `reason`, `decided_by`, with
#'   the file it was saved to in `attr(, "path")` and the set in
#'   `attr(, "documents")`. Edit `keep` and [dragon_questions_save()] it.
#' @export
#' @examples
#' if (interactive()) {
#' docs <- dragon_documents("policies/")
#' qa <- dragon_questions(docs)                      # local model, background, waits
#' qa                                                # how many kept, and why not
#' qa$keep[qa$id == "p0007"] <- TRUE                 # rescue one after reading it
#' dragon_questions_save(qa)
#' ds <- dragon_questions_dataset(qa, docs)          # excerpts retrieved into every prompt
#' run <- dragon_train(ds, "Qwen/Qwen2.5-0.5B-Instruct", wait = TRUE)
#' }
dragon_questions <- function(docs, generator = NULL, n_per_chunk = 3, mix = TRUE, include_quotes = FALSE, include_code = TRUE,
                             include_changelog = FALSE, load_in_4bit = "auto", batch_size = 4,
                             max_new_tokens = 420, wait = TRUE) {
  docs <- as_documents(docs)
  check_number(n_per_chunk, "n_per_chunk", min = 1, max = 10, integer = TRUE)
  out_dir <- file.path(docs$dir, "questions")
  dir.create(out_dir, showWarnings = FALSE)
  out <- file.path(out_dir, paste0(format(Sys.time(), "%Y%m%d-%H%M%S"), ".jsonl"))
  sel <- c("--per-chunk", as.character(as.integer(n_per_chunk)),
           if (isTRUE(include_quotes)) "--include-quotes", if (!isTRUE(include_code)) "--skip-code",
           if (isTRUE(include_changelog)) "--include-changelog", if (isTRUE(mix)) "--mix")

  local_model <- is.null(generator) || (is.character(generator) && length(generator) == 1L)
  if (!local_model) {
    # A teacher called from R: prompts from Python, replies from the teacher,
    # parsing and filtering back in Python so both paths judge pairs alike.
    fn <- as_llm(generator, role = "teacher", max_new_tokens = 200L * as.integer(n_per_chunk) + 100L)
    res <- run_python("dragonfarm.questions", c("prompts", "--dir", docs$dir, sel))
    if (res$status != 0) python_failure_message(res, "Preparing question prompts")
    prompts <- jsonlite::fromJSON(res$stdout, simplifyVector = FALSE)
    if (!length(prompts)) cli::cli_abort("No chunks to write questions from (all were quotes, code, or changelog entries that are skipped by default).")
    cli::cli_alert_info("Asking {llm_label(fn)} for questions on {length(prompts)} chunk{?s}.")
    replies <- call_llm(fn, vapply(prompts, `[[`, "", "prompt"), what = "teacher")
    raw <- tempfile(fileext = ".json")
    jsonlite::write_json(lapply(seq_along(prompts), function(i) list(chunk_id = prompts[[i]]$chunk_id, output = replies[i])),
                         raw, auto_unbox = TRUE)
    res <- run_python("dragonfarm.questions", c("filter", "--dir", docs$dir, "--raw", raw, "--out", out, "--generator", llm_label(fn)))
    if (res$status != 0) python_failure_message(res, "Filtering questions")
    qa <- dragon_questions_load(out)
    report_questions(qa)
    return(qa)
  }

  model <- generator %||% default_answer_model()
  require_gpu_free("Writing practice questions")
  if (worker_alive()) {
    cli::cli_alert_info("Stopping the local inference worker so the generator has the whole GPU.")
    dragon_worker_stop()
  }
  py <- dragon_python(quiet = TRUE)
  args <- c("-m", "dragonfarm.questions", "generate", "--dir", docs$dir, "--out", out, "--model", model,
            "--load-in-4bit", tolower(as.character(load_in_4bit)), "--batch-size", as.character(as.integer(batch_size)),
            "--max-new-tokens", as.character(as.integer(max_new_tokens)), sel,
            if (!is.null(rev <- preset_revision(model))) c("--revision", rev))
  log <- paste0(out, ".log")
  p <- processx::process$new(py, args, stdout = log, stderr = "2>&1", env = python_env(), cleanup = TRUE,
                             windows_hide_window = TRUE)
  job <- structure(list(process = p, out = out, progress = paste0(out, ".progress.json"), log = log,
                        documents = docs$dir, model = model, started = Sys.time()), class = "dragon_questions_job")
  cli::cli_alert_info("Writing questions with {.val {model}} in the background. Progress: {.path {basename(out)}}")
  if (!wait) return(job)
  dragon_questions_wait(job)
}

#' @rdname dragon_questions
#' @param job A job from `dragon_questions(wait = FALSE)`.
#' @export
dragon_questions_progress <- function(job) {
  p <- if (file.exists(job$progress)) tryCatch(read_json(job$progress), error = function(e) NULL)
  alive <- tryCatch(job$process$is_alive(), error = function(e) FALSE)
  if (is.null(p)) p <- list(state = if (alive) "loading" else "failed", done = 0L, total = NA_integer_, pairs = 0L, kept = 0L)
  if (!alive && !identical(p$state, "done")) p$state <- "failed"
  p$alive <- alive
  p
}

#' @rdname dragon_questions
#' @export
dragon_questions_wait <- function(job) {
  id <- cli::cli_progress_bar("Writing questions", total = NA, clear = TRUE)
  repeat {
    p <- dragon_questions_progress(job)
    if (!is.na(p$total) && p$total > 0) {
      # cli closes a bar by itself when `set` reaches `total`, and the generator
      # reports every chunk done a moment before it writes "done"; hold the bar
      # one short of full until then, and never let a closed bar end the wait.
      at <- if (identical(p$state, "done")) p$total else min(p$done, p$total - 1L)
      try(cli::cli_progress_update(id = id, set = at, total = p$total,
                                   status = sprintf("%d of %d chunks, %d pairs, %d kept", p$done, p$total, p$pairs, p$kept)),
          silent = TRUE)
    }
    if (identical(p$state, "done")) break
    if (identical(p$state, "failed")) {
      try(cli::cli_progress_done(id = id), silent = TRUE)
      cli::cli_abort(c("Question generation failed.", "i" = "Last lines of the log:", " " = paste(tail_lines(job$log, 12), collapse = "\n")))
    }
    Sys.sleep(1)
  }
  try(cli::cli_progress_done(id = id), silent = TRUE)
  qa <- dragon_questions_load(job$out)
  report_questions(qa)
  qa
}

report_questions <- function(qa) {
  n <- nrow(qa); k <- sum(qa$keep)
  cli::cli_alert_success("{n} question{?s} written, {k} kept by the filters ({if (n) round(100 * k / n) else 0}%). Review them before training.")
  if (n > k) {
    why <- sort(table(sub(" \\(.*", "", qa$reason[!qa$keep])), decreasing = TRUE)
    cli::cli_text("Rejected: {paste(sprintf('%s (%d)', names(why), why), collapse = ', ')}.")
  }
  invisible(qa)
}

#' Load, save, and list question sets
#'
#' @param path A questions file (`<set>/questions/<stamp>.jsonl`), or a
#'   `dragon_questions` object for `dragon_questions_save()`.
#' @param qa A `dragon_questions` data frame whose `keep` column you edited.
#' @param docs A `dragon_documents` object or directory.
#' @return `dragon_questions_load()` and `dragon_questions_save()` return the
#'   `dragon_questions` data frame; `dragon_questions_list()` a data frame of
#'   the set's question files with counts.
#' @export
dragon_questions_load <- function(path) {
  check_string(path, "path")
  if (!file.exists(path)) cli::cli_abort("{.path {path}} does not exist.", class = "dragonfarm_error", code = "FILE_NOT_FOUND")
  recs <- read_jsonl(path)
  df <- data.frame(
    id = vapply(recs, function(r) r$id, ""), chunk_id = vapply(recs, function(r) r$chunk_id, ""),
    source = vapply(recs, function(r) r$source, ""), section = vapply(recs, function(r) r$section %||% "", ""),
    question = vapply(recs, function(r) r$question, ""), answer = vapply(recs, function(r) r$answer, ""),
    keep = vapply(recs, function(r) isTRUE(r$keep), NA), reason = vapply(recs, function(r) r$reason %||% NA_character_, ""),
    decided_by = vapply(recs, function(r) r$decided_by %||% "filter", ""), stringsAsFactors = FALSE
  )
  meta_path <- paste0(path, ".meta.json")
  meta <- if (file.exists(meta_path)) tryCatch(read_json(meta_path), error = function(e) NULL)
  structure(df, path = normalizePath(path, winslash = "/"), documents = dirname(dirname(normalizePath(path, winslash = "/"))),
            meta = meta, class = c("dragon_questions", "data.frame"))
}

#' @rdname dragon_questions_load
#' @export
dragon_questions_save <- function(qa, path = attr(qa, "path")) {
  if (!inherits(qa, "dragon_questions")) cli::cli_abort("{.arg qa} must come from {.fn dragon_questions}.")
  check_string(path, "path")
  recs <- lapply(seq_len(nrow(qa)), function(i) list(
    id = qa$id[i], chunk_id = qa$chunk_id[i], source = qa$source[i], section = qa$section[i],
    question = qa$question[i], answer = qa$answer[i], keep = isTRUE(qa$keep[i]),
    reason = if (is.na(qa$reason[i])) NULL else qa$reason[i],
    decided_by = if (isTRUE(qa$keep[i]) != is.na(qa$reason[i])) "person" else qa$decided_by[i]
  ))
  write_jsonl(recs, path)
  invisible(dragon_questions_load(path))
}

#' @rdname dragon_questions_load
#' @export
dragon_questions_list <- function(docs) {
  docs <- as_documents(docs)
  files <- sort(list.files(file.path(docs$dir, "questions"), pattern = "^[0-9-]+\\.jsonl$", full.names = TRUE), decreasing = TRUE)
  rows <- lapply(files, function(f) {
    meta_path <- paste0(f, ".meta.json")
    m <- if (file.exists(meta_path)) tryCatch(read_json(meta_path), error = function(e) NULL)
    n <- length(readLines(f, warn = FALSE))
    data.frame(file = normalizePath(f, winslash = "/"), stamp = sub("\\.jsonl$", "", basename(f)),
               generator = m$generator %||% NA_character_, pairs = n, kept = as.integer(m$n_kept %||% NA),
               finished = !is.null(m), stringsAsFactors = FALSE)
  })
  if (!length(rows)) return(data.frame(file = character(), stamp = character(), generator = character(),
                                       pairs = integer(), kept = integer(), finished = logical(), stringsAsFactors = FALSE))
  do.call(rbind, rows)
}

#' Training data from reviewed questions
#'
#' Builds the dataset the fine-tune trains on: for every kept question, the
#' `k` most relevant excerpts are retrieved from the documents (by the
#' question, not the chunk it was written from, so training matches what
#' happens at answer time) and placed in the prompt ahead of it; the answer
#' is the response. This is the setup that beat a plain fine-tune in the
#' prototypes: the model learns to use excerpts, and the documents stay the
#' source of truth and can change later without retraining.
#'
#' @param qa A `dragon_questions` data frame (only rows with `keep = TRUE` are used).
#' @param docs The document set; defaults to the one the questions came from.
#' @param k Excerpts per prompt.
#' @param cite Append the excerpt number of the chunk each pair was written
#'   from to its answer (`" [2]"`), the way [dragon_ask()] cites, so the tuned
#'   model keeps citing. Answers that already contain a `[n]` marker are left
#'   alone. The source chunk is always among the excerpts: when retrieval
#'   misses it, it takes the last slot.
#' @param negatives Share of extra rows, relative to the kept questions, in
#'   which a question is shown with excerpts from a different section of the
#'   documents and the response is "The documents do not cover this." Without
#'   them every training prompt has its answer in the excerpts, and fine-tuned
#'   models learn to answer everything. Tuned on R's manuals, a 0.5B, 1.5B,
#'   and 3B declined 0, 1, and 5 of 15 questions the manuals do not cover;
#'   with 15 percent negatives all three declined 15 of 15, and answered 26,
#'   28, and 30 of 32 answerable questions, against 24, 29, and 30 without.
#'   `0` turns them off.
#' @return A mapped `dragon_dataset` ready for [dragon_train()]. Its data has a
#'   `negative` column marking the "not covered" rows.
#' @export
dragon_questions_dataset <- function(qa, docs = NULL, k = 4, cite = TRUE, negatives = 0.15) {
  check_number(negatives, "negatives", min = 0, max = 1)
  if (!inherits(qa, "dragon_questions")) cli::cli_abort("{.arg qa} must come from {.fn dragon_questions}.")
  docs <- as_documents(docs %||% attr(qa, "documents"))
  kept <- qa[qa$keep, , drop = FALSE]
  if (!nrow(kept)) cli::cli_abort("No kept questions. Review the set and keep at least a few.")
  written_from <- attr(qa, "meta")$chunks_md5
  now <- unname(tools::md5sum(file.path(docs$dir, "chunks.jsonl")))
  if (!is.null(written_from) && !identical(written_from, now)) {
    cli::cli_warn(c(
      "The document set {.val {docs$name}} was re-read after these questions were written.",
      "i" = "Chunk ids may now point at different text, so the source excerpt added to each prompt can be wrong.",
      "i" = "Write the questions again with {.fn dragon_questions}, or review them again before training."
    ))
  }
  hits <- dragon_retrieve(docs, kept$question, k = k)
  if (is.null(hits$query)) hits$query <- kept$question[1]   # one question: dragon_retrieve drops the column
  chunks <- dragon_chunks(docs)
  built <- lapply(seq_len(nrow(kept)), function(i) {
    h <- hits[hits$query == kept$question[i], , drop = FALSE]
    at <- match(kept$chunk_id[i], h$id)
    if (is.na(at)) {
      # The chunk this pair was written from was not retrieved for its own
      # question (about one prompt in ten on a manual). Training on that would
      # teach the model to answer without support, so put the chunk in the last
      # slot instead of the weakest hit.
      src <- chunks[match(kept$chunk_id[i], chunks$id), , drop = FALSE]
      if (nrow(src)) {
        at <- max(1L, min(k, nrow(h) + if (nrow(h) < k) 1L else 0L))
        if (nrow(h) >= at) h <- h[-at, , drop = FALSE]
        if (is.null(h$page)) h$page <- NA_integer_
        h <- rbind(h[, c("id", "source", "section", "page", "text"), drop = FALSE],
                   data.frame(id = src$id, source = src$source, section = src$section, page = src$page,
                              text = src$text, stringsAsFactors = FALSE))
        at <- nrow(h)
      }
    }
    h$n <- seq_len(nrow(h))
    context <- paste(sprintf("[%d] %s\n%s", h$n, source_label(h$source, h$section, h$page %||% NA), h$text), collapse = "\n\n")
    answer <- kept$answer[i]
    if (isTRUE(cite) && !is.na(at) && !grepl("\\[\\d+\\]", answer)) answer <- paste0(answer, " [", at, "]")
    list(context = context, answer = answer)
  })
  df <- data.frame(question = kept$question, context = vapply(built, `[[`, "", "context"),
                   answer = vapply(built, `[[`, "", "answer"), source = kept$source, negative = FALSE,
                   stringsAsFactors = FALSE)
  df <- rbind(df, not_covered_rows(df, kept, chunks, negatives))
  ds <- dragon_dataset(df, name = paste0(docs$name, " questions"))
  dragon_map(ds, prompt = "Documentation excerpts:\n{context}\n\nQuestion: {question}", response = "answer")
}

not_covered_answer <- "The documents do not cover this."

# "Not covered" rows: a question paired with the excerpts built for another
# question whose source chunk sits in a different section, so the excerpts do
# not hold its answer. Deterministic for a given question set.
not_covered_rows <- function(df, kept, chunks, share) {
  n <- round(share * nrow(df))
  if (n < 1 || nrow(df) < 2) return(df[0, , drop = FALSE])
  section <- chunks$section[match(kept$chunk_id, chunks$id)]
  section[is.na(section)] <- kept$chunk_id[is.na(section)]
  key <- paste(kept$source, section)
  withr::with_seed(42, {
    pick <- sample(nrow(df), min(n, nrow(df)))
    from <- vapply(pick, function(i) {
      pool <- which(key != key[i])
      if (!length(pool)) pool <- setdiff(seq_len(nrow(df)), i)
      pool[sample.int(length(pool), 1)]
    }, integer(1))
  })
  data.frame(question = df$question[pick], context = df$context[from], answer = not_covered_answer,
             source = df$source[pick], negative = TRUE, stringsAsFactors = FALSE)
}

#' @export
print.dragon_questions <- function(x, ...) {
  # A subset such as qa[!qa$keep, c("question", "reason")] loses the file
  # attributes and usually some columns; show it as the plain table it is.
  if (is.null(attr(x, "path")) || !all(c("question", "answer", "keep") %in% names(x))) {
    return(print(as.data.frame(unclass(x), stringsAsFactors = FALSE), ...))
  }
  n <- nrow(x); k <- sum(x$keep)
  m <- attr(x, "meta")
  cli::cli_h3("{n} question{?s} from {basename(attr(x, 'documents') %||% 'documents')}{if (!is.null(m$generator)) paste0(', written by ', m$generator) else ''}")
  cli::cli_text("{k} kept ({if (n) round(100 * k / n) else 0}%), {n - k} rejected. Edit {.code $keep} and {.fn dragon_questions_save}; then {.fn dragon_questions_dataset}.")
  if (n > k) {
    why <- sort(table(sub(" \\(.*", "", x$reason[!x$keep])), decreasing = TRUE)
    cli::cli_text("Rejected: {paste(sprintf('%s (%d)', names(why), why), collapse = ', ')}.")
  }
  show <- utils::head(x[x$keep, c("source", "question", "answer")], 5)
  if (nrow(show)) {
    cli::cli_text("")
    for (i in seq_len(nrow(show))) cli::cli_text("{.strong Q:} {show$question[i]}\n   {.strong A:} {show$answer[i]}")
    if (k > 5) cli::cli_text("... and {k - 5} more.")
  }
  invisible(x)
}
