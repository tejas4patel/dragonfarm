# Replaying recorded work. Every successful tool call records a fingerprint
# of its result and what it depended on (the document set's chunks, the model
# and its pinned revision). A replay runs the same call again and says
# whether the result matches and, if not, whether the context changed (a
# re-read set, another model) or the output changed on the same context.
# Only read-only tools are replayed; anything with a side effect is not.

result_hash <- function(x) rlang::hash(as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", digits = NA)))

# What a call depended on, as far as the catalogue knows.
tool_context <- function(args, result = NULL, runs_dir = dragon_runs_dir()) {
  ctx <- list()
  if (is.character(args$set) && length(args$set) == 1) {
    name <- basename(args$set)
    v <- tryCatch(store_get(store_open(runs_dir),
                                  "SELECT version, chunks_md5 FROM set_versions WHERE set_name = ? ORDER BY version DESC LIMIT 1",
                                  params = list(name)), error = function(e) NULL)
    if (!is.null(v) && nrow(v)) ctx$set <- list(name = name, version = v$version, chunks_md5 = v$chunks_md5)
  }
  model <- if (is.list(result) && is.character(result$model) && nzchar(result$model)) result$model else args$model
  if (is.character(model) && length(model) == 1) ctx$model <- list(id = model, revision = preset_revision(model))
  ctx
}

store_event <- function(id, runs_dir = dragon_runs_dir()) {
  ev <- store_get(store_open(runs_dir), "SELECT * FROM events WHERE id = ?", params = list(as.integer(id)))
  if (!nrow(ev)) cli::cli_abort("There is no event {id} in the catalogue.", class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  ev <- as.list(ev[1, ])
  ev$detail <- if (is.na(ev$detail)) list() else jsonlite::fromJSON(ev$detail, simplifyVector = FALSE)
  ev
}

# Which parts of the context differ between the recording and now.
context_changes <- function(then, now) {
  out <- character()
  if (!identical(then$set$chunks_md5, now$set$chunks_md5)) {
    out <- c(out, sprintf("document set %s was read again (version %s, now %s)", then$set$name %||% now$set$name %||% "?",
                          then$set$version %||% "?", now$set$version %||% "?"))
  }
  if (!identical(then$model$id, now$model$id) || !identical(then$model$revision, now$model$revision)) {
    out <- c(out, sprintf("model %s@%s, now %s@%s", then$model$id %||% "?", then$model$revision %||% "-",
                          now$model$id %||% "?", now$model$revision %||% "-"))
  }
  out
}

# Run a recorded tool call again and compare. Never throws for a recorded
# event: returns list(ok, matches, changes, then, now) or ok = FALSE with a code.
tool_replay <- function(id, runs_dir = dragon_runs_dir()) {
  ev <- store_event(id, runs_dir)
  if (!identical(ev$kind, "tool") || !identical(as.integer(ev$ok), 1L) || is.null(ev$detail$result_hash)) {
    return(list(ok = FALSE, code = "NOT_REPLAYABLE", error = sprintf("Event %s is not a recorded successful tool call.", id)))
  }
  tool <- tool_registry()[[ev$name]]
  if (is.null(tool) || !identical(tool$side_effect, "read_only")) {
    return(list(ok = FALSE, code = "NOT_REPLAYABLE",
                error = sprintf("'%s' changes something, so it is not replayed.", ev$name)))
  }
  args <- ev$detail$args %||% list()
  out <- tool_call(ev$name, args)
  if (!isTRUE(out$ok)) return(list(ok = FALSE, code = out$code, error = out$error))
  now <- tool_context(args, out$result, runs_dir)
  matches <- identical(result_hash(out$result), ev$detail$result_hash)
  changes <- context_changes(ev$detail$context %||% list(), now)
  store_record_event("replay", ev$name, ok = matches, detail = list(of = as.integer(id), changes = changes), runs_dir = runs_dir)
  list(ok = TRUE, matches = matches, changes = changes, then = ev$detail$result_preview, now = result_preview(out$result))
}

result_preview <- function(x, n = 300L) {
  s <- as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null"))
  if (nchar(s) > n) paste0(substr(s, 1, n), " ...") else s
}

# Run a recorded agent task again: the same goal, agent and model. Matches
# when the answer and the tools used are the same.
agent_replay <- function(id, runs_dir = dragon_runs_dir()) {
  ev <- store_event(id, runs_dir)
  d <- ev$detail
  if (!identical(ev$kind, "agent_run") || is.null(d$answer_hash) || is.null(d$model)) {
    return(list(ok = FALSE, code = "NOT_REPLAYABLE", error = sprintf("Event %s is not a recorded agent task.", id)))
  }
  r <- agent_run(d$goal, agent = ev$name, model = d$model, max_steps = d$max_steps)
  tools_then <- unlist(d$tools) %||% character()
  tools_now <- vapply(r$steps, `[[`, "", "tool")
  matches <- identical(result_hash(r$answer), d$answer_hash) && identical(tools_then, tools_now)
  store_record_event("replay", ev$name, ok = matches, detail = list(of = as.integer(id), kind = "agent_run"), runs_dir = runs_dir)
  list(ok = TRUE, matches = matches, tools_then = tools_then, tools_now = tools_now, answer = r$answer)
}
