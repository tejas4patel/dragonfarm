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

# Replay a recorded answer from dragon_ask(): the same question, set, model
# and settings. Says whether the excerpts found, the prompt and the answer
# are the same, and what changed when they are not (the set re-read, the
# model's revision). Answers from a server backend are not replayed.
ask_replay <- function(id, runs_dir = dragon_runs_dir()) {
  ev <- store_event(id, runs_dir)
  d <- ev$detail
  not <- function(why) list(ok = FALSE, code = "NOT_REPLAYABLE", error = why)
  if (!identical(ev$kind, "ask") || is.null(d$answer_hash) || is.null(d$question)) return(not(sprintf("Event %s is not a recorded answer.", id)))
  label <- sub(" [(]base[)]$", "", d$model %||% "")
  # Recorded since this was added; older answers: a run here or a Hub id
  # ("org/name") ran locally, anything else came from a server.
  server <- d$settings$server %||% !(dir.exists(file.path(runs_dir, label)) || grepl("/", label, fixed = TRUE))
  if (!nzchar(label) || isTRUE(server)) return(not("The answer came from a model server, which this cannot run again."))
  dir <- file.path(runs_dir, "documents", d$set %||% "")
  if (!dir.exists(dir)) return(not(sprintf("The document set %s is no longer in this runs folder.", d$set %||% "?")))
  docs <- dragon_documents_load(dir)
  model <- if (dir.exists(file.path(runs_dir, label))) dragon_run(file.path(runs_dir, label)) else label
  s <- d$settings %||% list()
  a <- dragon_ask(docs, d$question, model = model, k = as.integer(s$k %||% 4L), compare = isTRUE(s$compare),
                  temperature = s$temperature %||% 0, top_p = s$top_p %||% 0.9,
                  max_new_tokens = as.integer(s$max_new_tokens %||% 600L), base = isTRUE(s$base))
  now <- if (!is.na(a$trace %||% NA)) store_event(a$trace, runs_dir)$detail else list()
  ids <- function(src) vapply(src %||% list(), function(x) as.character(x$id %||% ""), "")
  same_excerpts <- identical(ids(d$sources), ids(now$sources))
  same_prompt <- identical(d$prompt_hash, now$prompt_hash)
  matches <- identical(d$answer_hash, now$answer_hash %||% result_hash(a$answer))
  changes <- as.character(c(
    if (!identical(d$chunks_md5, now$chunks_md5)) sprintf("document set %s was read again", d$set),
    if (!identical(d$revision, now$revision)) sprintf("model revision %s, now %s", d$revision %||% "-", now$revision %||% "-"),
    if (!same_excerpts) "different excerpts were found",
    if (same_excerpts && !same_prompt) "the prompt changed (a newer dragonfarm words it differently)"
  ))
  store_record_event("replay", "ask", ok = matches, detail = list(of = as.integer(id), kind = "ask", changes = changes,
                                                                  same_excerpts = same_excerpts, same_prompt = same_prompt),
                     runs_dir = runs_dir)
  list(ok = TRUE, matches = matches, same_excerpts = same_excerpts, same_prompt = same_prompt, changes = changes,
       then = d$answer, now = a$answer)
}

# A recorded answer, readable: what was asked, what came back, from which
# model and which version of the set, and the excerpts behind it. Excerpt
# text is shown only while the set is unchanged since the answer.
trace_view <- function(d, runs_dir = dragon_runs_dir()) {
  dir <- file.path(runs_dir, "documents", d$set %||% "")
  chunks_file <- file.path(dir, "chunks.jsonl")
  same_set <- file.exists(chunks_file) && identical(unname(tools::md5sum(chunks_file)), d$chunks_md5)
  text <- if (same_set) {
    ch <- tryCatch(dragon_chunks(dragon_documents_load(dir)), error = function(e) NULL)
    function(id) if (is.null(ch)) "" else ch$text[match(id, ch$id)] %||% ""
  } else function(id) ""
  kv <- function(k, v) if (length(v) && !is.na(v[1]) && nzchar(v[1])) shiny::div(class = "kv", shiny::span(k), shiny::strong(v))
  src <- d$sources %||% list()
  shiny::div(class = "trace-view",
    kv("Question", d$question),
    shiny::div(class = "bubble assistant", shiny::span(class = "role", d$model %||% "model"), shiny::div(class = "content md", md_html(d$answer %||% ""))),
    kv("Model revision", d$revision), kv("Adapter", d$adapter),
    kv("Document set", sprintf("%s (reader %s)", d$set %||% "?", d$reader %||% "?")),
    shiny::p(class = "small", if (same_set) "The set is unchanged since this answer; the excerpts below are the ones it saw."
                              else "The set has been read again (or moved) since this answer, so excerpt text is not shown; the record keeps which excerpts were used."),
    shiny::tags$ol(class = "trace-excerpts", lapply(src, function(s) {
      shiny::tags$li(
        shiny::strong(source_label(s$source %||% "?", s$section %||% "", s$page %||% NA_integer_)),
        if (isTRUE(s$cited)) shiny::span(class = "pill succeeded", "cited"),
        if (same_set) shiny::div(class = "small", text(s$id))
      )
    })),
    kv("Settings", paste(sprintf("%s = %s", names(d$settings %||% list()), vapply(d$settings %||% list(), function(x) paste(format(x), collapse = ","), "")), collapse = ", ")),
    kv("Prompt fingerprint", d$prompt_hash)
  )
}
