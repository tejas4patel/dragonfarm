#' Talk to a model, with memory of the conversation
#'
#' A conversation object that keeps the message history and sends all of it
#' on every turn, so the model has context. Works with any backend: the
#' local worker, Ollama, or a remote server. Transcripts use the same
#' message format as training data, so a good conversation can become an
#' example.
#'
#' @param x What answers: a `dragon_run`, adapter or model directory, or
#'   model id. Ignored by server backends, which serve a fixed model.
#' @param system Optional system prompt, kept at the top of every turn.
#' @param backend Where to run inference. See [dragon_backend].
#' @param max_new_tokens,temperature,top_p Generation settings.
#' @param base Talk to what the run started from instead of the run.
#' @param runs_dir Where feedback from `$rate()` and `$edit()` is recorded
#'   (under `feedback/`). See [dragon_feedback()].
#' @param context_window Approximate token budget for the conversation
#'   (system prompt plus history), such as a small model's 2K to 8K
#'   context. When the next turn would go over it, `$say()` drops the
#'   oldest user/assistant pair and tries again until it fits, keeping the
#'   system prompt and the most recent turns. `NULL` (the default) never
#'   drops turns. The token count is a rough estimate (about 4 characters
#'   per token), not the model's own tokenizer.
#' @param documents A `dragon_documents` set (see [dragon_documents()]).
#'   When given, every user turn is answered with the `k` most relevant
#'   excerpts in front of the model and an instruction to cite them, as in
#'   [dragon_ask()]. The history keeps the plain turns; `$sources()` returns
#'   the excerpts behind the last reply.
#' @param k Excerpts to retrieve per turn when `documents` is set.
#' @return A `dragon_chat` object with methods:
#'   `$say(text, on_token = NULL)` sends a user turn and returns the reply
#'   (streaming pieces to `on_token` when the backend supports it);
#'   `$history()` returns the messages; `$reset()` clears them; `$undo()`
#'   drops the last exchange; `$regenerate()` asks again for the last reply;
#'   `$rate("up")` or `$rate("down")` records a verdict on the last reply
#'   and `$edit(text)` replaces it with a better one, both saved as feedback
#'   that [dragon_feedback()] turns into training data;
#'   `$context_usage()` reports the estimated tokens used, the window, and
#'   how many turns have been dropped to stay under it (`NULL` when
#'   `context_window` is not set);
#'   `$save(path)` and `dragon_chat_load(path)` write and read a transcript;
#'   `$as_example()` returns the conversation as one training row.
#' @export
#' @examples
#' if (interactive()) {
#' chat <- dragon_chat(run, system = "You are a concise support agent.")
#' chat$say("My thermostat keeps dropping off Wi-Fi.")
#' chat$say("I tried that. What else?")   # the model sees the first exchange
#' chat$history()
#' chat$save("good-conversation.json")
#' }
dragon_chat <- function(x = NULL, system = NULL, backend = dragon_backend(), max_new_tokens = 600,
                        temperature = 0.7, top_p = 0.9, base = FALSE, runs_dir = dragon_runs_dir(),
                        context_window = NULL, documents = NULL, k = 4) {
  if (!is.null(documents)) documents <- as_documents(documents)
  if (is.null(x) && !is_server_backend(backend) && !is.null(documents)) x <- default_answer_model()
  target <- if (is_server_backend(backend)) NULL else {
    if (is.null(x)) cli::cli_abort("Say what should answer: a run, adapter, model directory, or model id.")
    t <- resolve_target(x)
    if (isTRUE(base)) t$adapter <- NULL
    t
  }
  self <- new.env(parent = emptyenv())
  self$backend <- backend
  self$target <- target
  self$system <- system
  self$documents <- documents
  self$k <- as.integer(check_number(k, "k", min = 1, integer = TRUE))
  self$last_sources <- NULL
  self$sources <- function() self$last_sources
  self$context_window <- if (!is.null(context_window)) as.integer(check_number(context_window, "context_window", min = 64, integer = TRUE))
  self$settings <- list(max_new_tokens = as.integer(max_new_tokens), temperature = temperature, top_p = top_p,
                        context_window = self$context_window)
  self$messages <- list()
  self$dropped_turns <- 0L
  self$runs_dir <- runs_dir
  self$label <- if (!is.null(target)) (if (!is.null(x) && inherits(x, "dragon_run")) x$id else basename(target$model)) else backend$model

  context_tokens <- function(msgs) sum(vapply(msgs, function(m) estimate_tokens(m$content), numeric(1)), 0)
  trim_for_context <- function(pending_text) {
    if (is.null(self$context_window)) return(invisible(0L))
    budget <- self$context_window - self$settings$max_new_tokens
    sys_tokens <- if (!is.null(self$system)) estimate_tokens(self$system) else 0L
    dropped <- 0L
    while (length(self$messages) >= 2 &&
           sys_tokens + context_tokens(self$messages) + estimate_tokens(pending_text) > budget) {
      self$messages <- self$messages[-c(1, 2)]
      dropped <- dropped + 1L
    }
    self$dropped_turns <- self$dropped_turns + dropped
    invisible(dropped)
  }
  self$context_usage <- function() {
    if (is.null(self$context_window)) return(NULL)
    sys_tokens <- if (!is.null(self$system)) estimate_tokens(self$system) else 0L
    tokens <- sys_tokens + context_tokens(self$messages)
    list(tokens = tokens, window = self$context_window, ratio = tokens / self$context_window,
        near_limit = tokens / self$context_window >= 0.85, dropped_turns = self$dropped_turns)
  }

  last_reply_index <- function() {
    n <- length(self$messages)
    if (n < 2 || !identical(self$messages[[n]]$role, "assistant")) cli::cli_abort("Nothing to rate yet: the last turn is not a model reply.")
    n
  }
  self$rate <- function(rating) {
    r <- if (identical(rating, "up") || identical(rating, 1) || identical(rating, 1L)) 1 else
         if (identical(rating, "down") || identical(rating, -1) || identical(rating, -1L)) -1 else
         cli::cli_abort("{.arg rating} must be \"up\" or \"down\" (1 or -1).")
    n <- last_reply_index()
    record_feedback(self$runs_dir, self$label, self$system, self$messages[seq_len(n - 1)], self$messages[[n]]$content, rating = r)
    invisible(self)
  }
  self$edit <- function(text) {
    check_string(text, "text")
    n <- last_reply_index()
    record_feedback(self$runs_dir, self$label, self$system, self$messages[seq_len(n - 1)], self$messages[[n]]$content, edited = text)
    self$messages[[n]]$content <- text
    invisible(self)
  }
  self$regenerate <- function(on_token = NULL) {
    n <- last_reply_index()
    last_user <- self$messages[[n - 1]]$content
    self$messages <- self$messages[seq_len(n - 2)]
    self$say(last_user, on_token = on_token)
  }

  self$say <- function(text, on_token = NULL) {
    check_string(text, "text")
    # With documents, the model sees this turn wrapped in retrieved excerpts;
    # the history keeps the plain question so transcripts stay readable and
    # usable as training examples.
    sent <- text
    system <- self$system
    if (!is.null(self$documents)) {
      hits <- chat_retrieve(self$documents, text, last_user_text(self$messages), self$k)
      sent <- documents_prompt(text, hits, mark = datamark_for(self$target))
      system <- documents_system(self$system, small = decline_note_for(self$target),
                                 full = full_answers_for(self$target))
      self$last_sources <- hits
    }
    trim_for_context(sent)
    turn <- c(self$messages, list(list(role = "user", content = text)))
    sent_turn <- c(self$messages, list(list(role = "user", content = sent)))
    convo <- if (!is.null(system)) c(list(list(role = "system", content = system)), sent_turn) else sent_turn
    reply <- backend_generate(self$backend, self$target, list(convo),
                              max_new_tokens = self$settings$max_new_tokens,
                              temperature = self$settings$temperature, top_p = self$settings$top_p,
                              on_token = on_token)[[1]]
    if (!is.null(self$documents) && citation_only(reply)) {
      # As in dragon_ask(): a reply that is only "[1]" gets one more turn.
      # Not streamed; the finished reply replaces what was streamed.
      retry <- c(convo, list(list(role = "assistant", content = reply),
                             list(role = "user", content = citation_retry_prompt)))
      again <- backend_generate(self$backend, self$target, list(retry),
                                max_new_tokens = self$settings$max_new_tokens,
                                temperature = self$settings$temperature, top_p = self$settings$top_p)[[1]]
      if (!citation_only(again)) reply <- again
      if (citation_only(reply)) {
        reply <- plain_answer(self$backend, self$target, text, self$last_sources, reply, system = self$system,
                              max_new_tokens = self$settings$max_new_tokens,
                              temperature = self$settings$temperature, top_p = self$settings$top_p)
      }
    }
    if (!is.null(self$documents) && !is.null(self$last_sources) && nrow(self$last_sources)) {
      self$last_sources$cited <- self$last_sources$n %in% parse_citations(reply, nrow(self$last_sources))
    }
    self$messages <- c(turn, list(list(role = "assistant", content = reply)))
    invisible(reply)
  }
  self$history <- function() self$messages
  self$reset <- function() {
    self$messages <- list()
    invisible(self)
  }
  self$undo <- function() {
    n <- length(self$messages)
    if (n >= 2) self$messages <- self$messages[seq_len(n - 2)]
    invisible(self)
  }
  self$as_example <- function() {
    msgs <- self$messages
    if (!is.null(self$system)) msgs <- c(list(list(role = "system", content = self$system)), msgs)
    list(messages = msgs)
  }
  self$save <- function(path) {
    write_json(list(
      format = "dragonfarm-chat", version = 1L, saved_at = now_iso(), label = self$label,
      system = self$system, settings = self$settings, messages = self$messages
    ), path)
    invisible(path)
  }
  class(self) <- "dragon_chat"
  self
}

#' @rdname dragon_chat
#' @param path A transcript written by `$save()`.
#' @export
dragon_chat_load <- function(path, x = NULL, backend = dragon_backend()) {
  check_string(path, "path")
  if (!file.exists(path)) cli::cli_abort("Transcript {.path {path}} does not exist.")
  rec <- read_json(path)
  if (!identical(rec$format, "dragonfarm-chat")) cli::cli_abort("{.path {path}} is not a dragonfarm chat transcript.")
  chat <- dragon_chat(x, system = rec$system, backend = backend,
                      max_new_tokens = rec$settings$max_new_tokens %||% 256,
                      temperature = rec$settings$temperature %||% 0.7, top_p = rec$settings$top_p %||% 0.9,
                      context_window = rec$settings$context_window)
  chat$messages <- rec$messages %||% list()
  chat
}

#' @export
print.dragon_chat <- function(x, ...) {
  n <- length(x$messages)
  cli::cli_text("{.cls dragon_chat} with {.strong {x$label}} via {backend_label(x$backend)}: {n %/% 2} turn{?s}")
  if (!is.null(x$system)) cli::cli_text("{.emph system:} {x$system}")
  usage <- x$context_usage()
  if (!is.null(usage)) {
    cli::cli_text("{.emph context:} ~{usage$tokens} of {usage$window} token{?s} ({round(100 * usage$ratio)}%){if (usage$dropped_turns) paste0(', ', usage$dropped_turns, ' turn', if (usage$dropped_turns != 1) 's', ' dropped to stay under the limit') else ''}")
  }
  tail <- if (n > 6) x$messages[(n - 5):n] else x$messages
  for (m in tail) {
    cli::cli_text("{.strong {m$role}:} {substr(gsub('\\\\s+', ' ', m$content), 1, 200)}")
  }
  invisible(x)
}

#' @export
`$.dragon_chat` <- function(x, name) get(name, envir = x, inherits = FALSE)

# A short follow-up that leans on the question before it ("And a boxplot?",
# "Which ones, then?") does not name what it is about, so searching it alone
# misses. Such a turn keeps its own best excerpts and fills the rest from a
# search with the previous question in front. On 22 follow-ups about the FDA
# guidances and R's manuals the right excerpt came back for 19 instead of 16;
# 12 changes of topic and 57 longer follow-ups were unaffected.
leans_on_previous <- function(text) {
  n_words <- length(strsplit(trimws(text), "[[:space:]]+")[[1]])
  n_words <= 10 && grepl("\\b(it|its|they|them|their|those|these|ones|then|afterwards|what about|how about)\\b|^\\s*and\\b",
                         text, ignore.case = TRUE, perl = TRUE)
}

last_user_text <- function(messages) {
  users <- Filter(function(m) identical(m$role, "user"), messages)
  if (length(users)) users[[length(users)]]$content else NULL
}

chat_retrieve <- function(docs, text, previous, k) {
  hits <- dragon_retrieve(docs, text, k = k)
  if (is.null(previous) || k < 2 || !leans_on_previous(text)) return(hits)
  own <- hits[seq_len(min(nrow(hits), k - k %/% 2)), , drop = FALSE]
  more <- dragon_retrieve(docs, paste(previous, text), k = k)
  more <- more[!more$id %in% own$id, , drop = FALSE]
  out <- rbind(own, more[seq_len(min(nrow(more), k - nrow(own))), , drop = FALSE])
  out$n <- seq_len(nrow(out))
  rownames(out) <- NULL
  out
}
