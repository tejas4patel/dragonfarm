# Human feedback from conversations, and how it becomes training data.
#
# Every rating, edit, or regeneration in a chat is appended to
# <runs_dir>/feedback/feedback.jsonl. dragon_feedback() turns those records
# into a conversations dataset (liked or edited replies, with their context)
# and a preference-pairs dataset (a liked and a disliked reply to the same
# prompt), ready for the next fine-tune or preference stage.

feedback_path <- function(runs_dir = dragon_runs_dir()) {
  dir <- file.path(runs_dir, "feedback")
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  file.path(dir, "feedback.jsonl")
}

# One record: what the user was shown and what they said about it.
record_feedback <- function(runs_dir, label, system, context, reply, rating = NULL, edited = NULL, source = "r") {
  rec <- list(
    ts = now_iso(), label = label, system = system, context = context, reply = reply,
    rating = rating, edited = edited, source = source
  )
  path <- feedback_path(runs_dir)
  con <- file(path, open = "a", encoding = "UTF-8")
  on.exit(close(con))
  writeLines(as.character(jsonlite::toJSON(rec, auto_unbox = TRUE, null = "null", digits = NA)), con)
  invisible(rec)
}

# How many ratings and edits there are, without writing any datasets.
feedback_counts <- function(runs_dir = dragon_runs_dir()) {
  path <- file.path(runs_dir, "feedback", "feedback.jsonl")
  recs <- if (file.exists(path)) read_jsonl(path) else list()
  rating <- vapply(recs, function(r) if (is.null(r$rating)) 0 else as.numeric(r$rating), 0)
  edited <- vapply(recs, function(r) !is.null(r$edited), TRUE)
  list(total = length(recs), liked = sum(rating > 0 & !edited), disliked = sum(rating < 0), edited = sum(edited))
}

context_key <- function(system, context) {
  as.character(jsonlite::toJSON(list(system = system, context = context), auto_unbox = TRUE, null = "null"))
}

#' Training data from chat feedback
#'
#' Ratings and edits made in [dragon_chat()] or the app's Chat panel are
#' saved under `feedback/` in the runs directory. This turns them into data
#' for the next stage:
#'
#' * `sft`: a conversations dataset ([dragon_conversations()]) of replies
#'   the user liked or edited, each with the turns that led to it. Edited
#'   text replaces the model's reply.
#' * `pairs`: a preference dataset ([dragon_map_pairs()]) for prompts that
#'   received both a liked (or edited) reply and a disliked one.
#'
#' Both are written as JSONL under `feedback/` so runs trained on them stay
#' reproducible through [dragon_code()].
#'
#' @param runs_dir Runs directory holding `feedback/feedback.jsonl`.
#' @param label Optional filter: only feedback given to this run id or
#'   backend model.
#' @return A list with `records` (a data frame of every feedback event),
#'   `sft` (dataset or `NULL`), and `pairs` (dataset or `NULL`).
#' @export
#' @examples
#' if (interactive()) {
#' fb <- dragon_feedback()
#' fb$records
#' better <- dragon_train(fb$sft, dpo, wait = TRUE)       # continue from the run people chatted with
#' dpo2 <- dragon_prefer(fb$pairs, better, wait = TRUE)
#' }
dragon_feedback <- function(runs_dir = dragon_runs_dir(), label = NULL) {
  path <- file.path(runs_dir, "feedback", "feedback.jsonl")
  recs <- if (file.exists(path)) read_jsonl(path) else list()
  if (!is.null(label)) recs <- Filter(function(r) identical(r$label, label), recs)
  records <- data.frame(
    ts = vapply(recs, function(r) r$ts %||% NA_character_, character(1)),
    label = vapply(recs, function(r) r$label %||% NA_character_, character(1)),
    rating = vapply(recs, function(r) if (is.null(r$rating)) NA_real_ else as.numeric(r$rating), numeric(1)),
    edited = vapply(recs, function(r) !is.null(r$edited), logical(1)),
    turns = vapply(recs, function(r) length(r$context %||% list()), integer(1)),
    reply = vapply(recs, function(r) substr(r$reply %||% "", 1, 80), character(1)),
    stringsAsFactors = FALSE
  )
  if (!length(recs)) return(list(records = records, sft = NULL, pairs = NULL))

  # SFT: liked or edited replies, with their context, as whole conversations.
  good <- Filter(function(r) !is.null(r$edited) || isTRUE((r$rating %||% 0) > 0), recs)
  sft <- NULL
  if (length(good)) {
    convs <- lapply(good, function(r) {
      msgs <- c(if (!is.null(r$system)) list(list(role = "system", content = r$system)), r$context,
                list(list(role = "assistant", content = r$edited %||% r$reply)))
      msgs
    })
    convs <- convs[!duplicated(vapply(convs, function(m) context_key(NULL, m), character(1)))]
    file <- file.path(runs_dir, "feedback", sprintf("%s-sft.jsonl", format(Sys.time(), "%Y%m%d-%H%M%S")))
    write_conversations(convs, file)
    sft <- dragon_conversations(file)
  }

  # Pairs: the same context with one liked (or edited) and one disliked reply.
  keys <- vapply(recs, function(r) context_key(r$system, r$context), character(1))
  pairs_rows <- list()
  for (k in unique(keys)) {
    group <- recs[keys == k]
    liked <- Filter(function(r) !is.null(r$edited) || isTRUE((r$rating %||% 0) > 0), group)
    disliked <- Filter(function(r) isTRUE((r$rating %||% 0) < 0), group)
    if (!length(liked) || !length(disliked)) next
    chosen <- liked[[length(liked)]]$edited %||% liked[[length(liked)]]$reply
    rejected <- disliked[[length(disliked)]]$reply
    if (identical(normalize_text(chosen), normalize_text(rejected))) next
    r <- group[[1]]
    pairs_rows[[length(pairs_rows) + 1]] <- list(
      prompt = last_role_content(r$context, "user"), chosen = chosen, rejected = rejected,
      system = r$system, turns = length(r$context)
    )
  }
  pairs <- NULL
  if (length(pairs_rows)) {
    file <- file.path(runs_dir, "feedback", sprintf("%s-pairs.jsonl", format(Sys.time(), "%Y%m%d-%H%M%S")))
    write_jsonl(pairs_rows, file)
    ds <- dragon_dataset(file)
    has_system <- any(!is.na(ds$data$system) & nzchar(ds$data$system))
    pairs <- dragon_map_pairs(ds, prompt = "prompt", chosen = "chosen", rejected = "rejected",
                              system = if (has_system) "system")
  }
  list(records = records, sft = sft, pairs = pairs)
}
