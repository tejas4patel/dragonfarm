# Judge-based evaluation: score a run's replies, or compare two runs, with an
# LLM as the judge. Generation goes through dragon_generate(); the judge is
# any function from prompts to replies, so an API model, a local model, or a
# test double all work the same way.

#' Judge a run's replies with a language model
#'
#' Two modes. With `against = NULL`, each reply is scored from 1 to 10 against
#' a rubric, using the held-out reference answer as ground truth when there
#' is one. With `against` set, the run's replies are compared pairwise with
#' another model's replies to the same prompts, and the judge picks a winner.
#' Pairwise judging asks each question twice with the two replies swapped, so
#' a judge that favours whichever answer comes first cannot bias the result.
#'
#' Prompts default to the run's held-out set, so scores are comparable across
#' runs that share a dataset. Results are written to `judge.json` in the run
#' directory and the summary is recorded in the run's status, where
#' [dragon_compare()] picks it up.
#'
#' @param x A `dragon_run` or run directory whose replies are judged.
#' @param against What to compare with: `NULL` for scoring alone, `"base"`
#'   for the model the run started from (its base model, or the run it
#'   continued), or another run, model id, or model directory.
#' @param prompts Prompts to use. Defaults to `n` prompts from the run's
#'   held-out rows.
#' @param n How many held-out prompts to use when `prompts` is `NULL`.
#' @param judge The judge: a function taking a character vector of prompts
#'   and returning a character vector of replies, an `ellmer` chat object, or
#'   a Hugging Face model id or local model directory to use as a local judge.
#'   See [dragon_judge_anthropic()] for the Claude API.
#' @param rubric What the judge should value. A sentence or two; a sensible
#'   default covers correctness, helpfulness, and following instructions.
#' @param system System prompt used when generating the replies being judged.
#' @param max_new_tokens Length cap for the generated replies.
#' @param seed Seed for sampling the held-out prompts.
#' @return A `dragon_judgement` object: a list with `mode`, `summary`, and
#'   `details` (one row per prompt).
#' @export
#' @examples
#' if (interactive()) {
#' # Did preference optimization help? Compare the DPO run with the SFT run it started from.
#' j <- dragon_judge(dpo, against = "base", judge = dragon_judge_anthropic())
#' j$summary
#'
#' # Absolute scores with a task-specific rubric.
#' dragon_judge(sft, rubric = "Reward replies that give concrete next steps and stay under 120 words.",
#'              judge = dragon_judge_anthropic(model = "claude-sonnet-5"))
#'
#' # A local judge: any model dragon_generate() can load.
#' dragon_judge(sft, against = "base", judge = "Qwen/Qwen2.5-1.5B-Instruct")
#' }
dragon_judge <- function(x, against = NULL, prompts = NULL, n = 20, judge = NULL, rubric = NULL,
                         system = NULL, max_new_tokens = 256, seed = 42) {
  run <- dragon_run(x)
  check_number(n, "n", min = 1, integer = TRUE)
  judge_fn <- as_judge(judge)
  set <- eval_prompts(run, prompts, n, seed)
  if (!length(set$prompts)) {
    # Small datasets hold nothing out; fall back to the training prompts.
    set <- eval_prompts(run, NULL, n, seed, split = "train")
    if (length(set$prompts)) cli::cli_alert_info("No held-out rows in this run; judging on {length(set$prompts)} training prompt{?s} instead.")
  }
  if (!length(set$prompts)) cli::cli_abort("No prompts to judge. Pass {.arg prompts} or train on a dataset with rows.")

  mode <- if (is.null(against)) "score" else "pairwise"
  cli::cli_alert_info("Generating {length(set$prompts)} repl{?y/ies} from {.strong {run$id}}.")
  a <- dragon_generate(run, set$prompts, system = system, max_new_tokens = max_new_tokens, temperature = 0)
  b <- NULL
  against_label <- NULL
  if (mode == "pairwise") {
    if (identical(against, "base")) {
      cfg <- run_config(run)
      against_label <- cfg$model$base_run %||% cfg$model$id
      cli::cli_alert_info("Generating from what it started with: {.val {against_label}}.")
      b <- dragon_generate(run, set$prompts, system = system, max_new_tokens = max_new_tokens, temperature = 0, base = TRUE)
    } else {
      other <- if (inherits(against, "dragon_run") || (is.character(against) && dir.exists(against) &&
                   file.exists(file.path(against, "config.json")) && file.exists(file.path(against, "adapter", "adapter_config.json")))) {
        dragon_run(against)
      } else {
        against
      }
      against_label <- if (inherits(other, "dragon_run")) other$id else as.character(other)
      cli::cli_alert_info("Generating from {.val {against_label}}.")
      b <- dragon_generate(other, set$prompts, system = system, max_new_tokens = max_new_tokens, temperature = 0)
    }
  }

  cli::cli_alert_info("Judging.")
  result <- if (mode == "score") {
    judge_scores(set$prompts, a, set$references, judge_fn, rubric)
  } else {
    judge_pairs(set$prompts, a, b, judge_fn, rubric, references = set$references)
  }
  result$run <- run$id
  result$against <- against_label
  result$judged_at <- now_iso()
  result$judge <- attr(judge_fn, "label") %||% "custom"
  class(result) <- "dragon_judgement"

  record_judgement(run, result)
  print(result)
  invisible(result)
}

# Prompts (and references) from the run's eval or train file, in any data format.
eval_prompts <- function(run, prompts, n, seed, split = "eval") {
  if (!is.null(prompts)) {
    if (!is.character(prompts) || !length(prompts)) cli::cli_abort("{.arg prompts} must be a character vector.")
    return(list(prompts = prompts, references = rep(NA_character_, length(prompts))))
  }
  cfg <- run_config(run)
  rel <- cfg$data[[split]]
  if (is.null(rel) || !file.exists(run_path(run, rel))) return(list(prompts = character(), references = character()))
  rows <- read_jsonl(run_path(run, rel))
  if (!length(rows)) return(list(prompts = character(), references = character()))
  user_of <- function(msgs) {
    hit <- Filter(function(m) identical(m$role, "user"), msgs)
    if (length(hit)) hit[[length(hit)]]$content else NA_character_
  }
  if (identical(cfg$data$format, "pairs")) {
    prompts <- vapply(rows, function(r) user_of(r$prompt), character(1))
    refs <- vapply(rows, function(r) as.character(r$chosen), character(1))
  } else if (identical(cfg$data$format, "prompts")) {
    prompts <- vapply(rows, function(r) user_of(r$prompt), character(1))
    refs <- vapply(rows, function(r) if (is.null(r$reference)) NA_character_ else as.character(r$reference), character(1))
  } else {
    prompts <- vapply(rows, function(r) user_of(r$messages), character(1))
    refs <- vapply(rows, function(r) as.character(r$messages[[length(r$messages)]]$content), character(1))
  }
  keep <- !is.na(prompts) & nzchar(prompts)
  prompts <- prompts[keep]
  refs <- refs[keep]
  if (length(prompts) > n) {
    idx <- seeded_sample_idx(length(prompts), n, seed)
    prompts <- prompts[idx]
    refs <- refs[idx]
  }
  list(prompts = prompts, references = refs)
}

default_rubric <- function() {
  paste(
    "Judge correctness first, then helpfulness and how well the reply follows the user's request.",
    "Prefer replies that are specific, accurate, and complete without padding.",
    "When a reference answer is given, treat it as ground truth for facts, but do not require identical wording."
  )
}

# Turn whatever the user passed as `judge` into function(prompts) -> replies.
as_judge <- function(judge) {
  as_llm(judge, role = "judge", temperature = 0, max_new_tokens = 400, system = judge_system_prompt())
}

#' Language models as functions: the Claude API and ellmer
#'
#' Judges, teachers, and students in dragonfarm are plain functions from a
#' character vector of prompts to a character vector of replies. These
#' helpers build such functions.
#'
#' `dragon_llm_anthropic()` calls the Claude API directly over HTTP with
#' refusal fallbacks enabled, reading the key from `ANTHROPIC_API_KEY`.
#' `dragon_llm_ellmer()` wraps any `ellmer` chat, so every provider ellmer
#' supports works; each prompt gets a fresh copy of the chat so no history
#' leaks between questions. The `dragon_judge_*()` variants are the same
#' with a system prompt that asks for JSON-only answers, which
#' [dragon_judge()] and [dragon_synthesize_pairs()] need.
#'
#' @param model Claude model id. The default is the most capable general
#'   model; `"claude-sonnet-5"` or `"claude-haiku-4-5"` are cheaper choices
#'   for large prompt sets.
#' @param system Optional system prompt.
#' @param api_key Anthropic API key.
#' @param max_tokens Reply length cap.
#' @param max_active How many requests to run at once.
#' @param temperature Sampling temperature, or `NULL` for the API default.
#' @return A function suitable for the `judge`, `teacher`, or `student`
#'   arguments of [dragon_judge()], [dragon_synthesize()], and
#'   [dragon_synthesize_pairs()].
#' @export
#' @examples
#' if (interactive()) {
#' teacher <- dragon_llm_anthropic(system = "You are a concise support agent.")
#' teacher(c("My thermostat drops off Wi-Fi.", "Invoice total looks wrong."))
#' }
dragon_llm_anthropic <- function(model = "claude-opus-5", system = NULL, api_key = Sys.getenv("ANTHROPIC_API_KEY"),
                                 max_tokens = 1024, max_active = 4, temperature = NULL) {
  check_string(model, "model")
  rlang::check_installed("httr2", reason = "to call the Claude API.")
  # Without an explicit key, look it up only when called: a judge or teacher
  # saved for a background pipeline must never carry the key to disk.
  from_env <- missing(api_key)
  if (from_env) rm(api_key) else force(api_key)
  # Evaluate every argument now: an unevaluated one keeps the caller's
  # frame alive inside the function, and that frame would be saved with it.
  force(system); force(max_tokens); force(max_active); force(temperature)
  fn <- function(prompts, schema = NULL) {
    api_key <- if (from_env) Sys.getenv("ANTHROPIC_API_KEY") else api_key
    if (!nzchar(api_key)) {
      cli::cli_abort(c("No Anthropic API key.", "i" = "Set {.envvar ANTHROPIC_API_KEY} or pass {.arg api_key}."))
    }
    outbound_check("https://api.anthropic.com", sprintf("Claude API (%s): %d prompt%s", model, length(prompts),
                                                       if (length(prompts) == 1) "" else "s"),
                   bytes = sum(nchar(unlist(prompts), type = "bytes")))
    reqs <- lapply(prompts, function(p) {
      anthropic_request(p, model = model, api_key = api_key, max_tokens = max_tokens, schema = schema,
                        system = system, temperature = temperature)
    })
    resps <- httr2::req_perform_parallel(reqs, max_active = max_active, on_error = "continue")
    vapply(resps, anthropic_reply_text, character(1))
  }
  attr(fn, "label") <- paste0("anthropic:", model)
  fn
}

#' @rdname dragon_llm_anthropic
#' @export
dragon_judge_anthropic <- function(model = "claude-opus-5", api_key = Sys.getenv("ANTHROPIC_API_KEY"),
                                   max_tokens = 1024, max_active = 4) {
  if (missing(api_key)) return(dragon_llm_anthropic(model = model, system = judge_system_prompt(),
                                                    max_tokens = max_tokens, max_active = max_active))
  dragon_llm_anthropic(model = model, system = judge_system_prompt(), api_key = api_key,
                       max_tokens = max_tokens, max_active = max_active)
}

judge_system_prompt <- function() {
  paste(
    "You are a careful evaluator of chatbot replies.",
    "Answer with a single JSON object and nothing else: no prose, no code fences."
  )
}

# JSON schemas the API can enforce for the two judging modes.
score_schema <- function() {
  list(
    type = "object",
    properties = list(
      score = list(type = "integer", minimum = 1, maximum = 10),
      reason = list(type = "string")
    ),
    required = list("score", "reason"),
    additionalProperties = FALSE
  )
}

pair_schema <- function() {
  list(
    type = "object",
    properties = list(
      winner = list(type = "string", enum = list("A", "B", "tie")),
      reason = list(type = "string")
    ),
    required = list("winner", "reason"),
    additionalProperties = FALSE
  )
}

# Judges that understand schemas get one; plain functions just get prompts.
call_judge <- function(judge_fn, prompts, schema) {
  if (length(formals(judge_fn)) >= 2) judge_fn(prompts, schema) else judge_fn(prompts)
}

anthropic_request <- function(prompt, model, api_key, max_tokens = 1024, schema = NULL, system = NULL, temperature = NULL) {
  body <- list(
    model = model,
    max_tokens = as.integer(max_tokens),
    fallbacks = "default",
    messages = list(list(role = "user", content = prompt))
  )
  if (!is.null(system)) body$system <- system
  if (!is.null(temperature)) body$temperature <- temperature
  if (!is.null(schema)) body$output_config <- list(format = list(type = "json_schema", schema = schema))
  httr2::request("https://api.anthropic.com/v1/messages") |>
    httr2::req_headers(
      `x-api-key` = api_key,
      `anthropic-version` = "2023-06-01",
      `anthropic-beta` = "server-side-fallback-2026-07-01",
      `content-type` = "application/json",
      .redact = "x-api-key"
    ) |>
    httr2::req_body_json(body, auto_unbox = TRUE) |>
    httr2::req_retry(max_tries = 3, retry_on_failure = TRUE) |>
    httr2::req_error(is_error = function(resp) FALSE)
}

# Text of a Messages API response, or an error marker the parser turns into NA.
anthropic_reply_text <- function(resp) {
  if (inherits(resp, "error")) return(paste0("__error__ ", conditionMessage(resp)))
  status <- httr2::resp_status(resp)
  body <- tryCatch(httr2::resp_body_json(resp, simplifyVector = FALSE), error = function(e) NULL)
  if (status >= 400 || is.null(body)) {
    msg <- body$error$message %||% paste("HTTP", status)
    return(paste0("__error__ ", msg))
  }
  if (identical(body$stop_reason, "refusal")) return("__error__ refusal")
  texts <- vapply(body$content %||% list(), function(blk) if (identical(blk$type, "text")) blk$text %||% "" else "", character(1))
  paste(texts[nzchar(texts)], collapse = "\n")
}

#' @rdname dragon_llm_anthropic
#' @param chat An `ellmer` chat object, for example `ellmer::chat_anthropic()`.
#' @export
dragon_llm_ellmer <- function(chat, system = NULL) {
  if (!inherits(chat, "Chat")) cli::cli_abort("{.arg chat} must be an ellmer chat object.")
  fn <- function(prompts) {
    vapply(prompts, function(p) {
      fresh <- chat$clone()
      if (!is.null(system)) fresh$set_system_prompt(system)
      as.character(fresh$chat(p, echo = "none"))
    }, character(1), USE.NAMES = FALSE)
  }
  attr(fn, "label") <- paste0("ellmer:", tryCatch(chat$get_model(), error = function(e) "chat"))
  fn
}

#' @rdname dragon_llm_anthropic
#' @export
dragon_judge_ellmer <- function(chat) {
  dragon_llm_ellmer(chat, system = judge_system_prompt())
}

# First JSON object in a reply, or NULL.
parse_judge_json <- function(text) {
  if (is.null(text) || is.na(text) || startsWith(text, "__error__")) return(NULL)
  text <- unfence(text)
  start <- regexpr("\\{", text)
  if (start < 0) return(NULL)
  candidate <- substr(text, start, nchar(text))
  # Trim to the last closing brace so trailing prose does not break parsing.
  end <- max(gregexpr("\\}", candidate)[[1]])
  if (end < 0) return(NULL)
  candidate <- substr(candidate, 1, end)
  tryCatch(jsonlite::fromJSON(candidate, simplifyVector = FALSE), error = function(e) NULL)
}

score_prompt <- function(prompt, reply, reference, rubric) {
  paste0(
    "Rate the reply below on a scale from 1 (useless or wrong) to 10 (excellent).\n",
    "Rubric: ", rubric %||% default_rubric(), "\n\n",
    "User request:\n", prompt, "\n\n",
    if (!is.na(reference)) paste0("Reference answer:\n", reference, "\n\n") else "",
    "Reply to rate:\n", reply, "\n\n",
    "Respond with JSON: {\"score\": <integer 1-10>, \"reason\": \"<one sentence>\"}"
  )
}

pair_prompt <- function(prompt, first, second, reference, rubric) {
  paste0(
    "Two chatbots answered the same request. Decide which reply is better.\n",
    "Rubric: ", rubric %||% default_rubric(), "\n\n",
    "User request:\n", prompt, "\n\n",
    if (!is.na(reference)) paste0("Reference answer:\n", reference, "\n\n") else "",
    "Reply A:\n", first, "\n\n",
    "Reply B:\n", second, "\n\n",
    "Respond with JSON: {\"winner\": \"A\" | \"B\" | \"tie\", \"reason\": \"<one sentence>\"}"
  )
}

# Score replies 1-10. Pure given the judge function.
judge_scores <- function(prompts, replies, references, judge_fn, rubric = NULL) {
  references <- references %||% rep(NA_character_, length(prompts))
  asks <- mapply(score_prompt, prompts, replies, references, MoreArgs = list(rubric = rubric), USE.NAMES = FALSE)
  raw <- call_judge(judge_fn, asks, score_schema())
  parsed <- lapply(raw, parse_judge_json)
  score <- vapply(parsed, function(p) {
    s <- suppressWarnings(as.numeric(p$score %||% NA))
    if (length(s) != 1 || is.na(s)) NA_real_ else min(max(s, 1), 10)
  }, numeric(1))
  reason <- vapply(parsed, function(p) as.character(p$reason %||% NA_character_), character(1))
  details <- data.frame(prompt = prompts, reference = references, reply = replies, score = score,
                        reason = reason, raw = raw, stringsAsFactors = FALSE)
  ok <- !is.na(score)
  list(
    mode = "score",
    summary = list(mean_score = if (any(ok)) mean(score[ok]) else NA_real_, n = sum(ok), unparsed = sum(!ok)),
    details = details
  )
}

# Pairwise verdicts with position swap. Pure given the judge function.
judge_pairs <- function(prompts, a, b, judge_fn, rubric = NULL, references = NULL) {
  references <- references %||% rep(NA_character_, length(prompts))
  ask_ab <- mapply(pair_prompt, prompts, a, b, references, MoreArgs = list(rubric = rubric), USE.NAMES = FALSE)
  ask_ba <- mapply(pair_prompt, prompts, b, a, references, MoreArgs = list(rubric = rubric), USE.NAMES = FALSE)
  raw <- call_judge(judge_fn, c(ask_ab, ask_ba), pair_schema())
  k <- length(prompts)
  winner_of <- function(txt) {
    p <- parse_judge_json(txt)
    w <- toupper(trimws(as.character(p$winner %||% NA_character_)))
    if (length(w) != 1 || is.na(w) || !w %in% c("A", "B", "TIE")) NA_character_ else w
  }
  w_ab <- vapply(raw[seq_len(k)], winner_of, character(1))
  w_ba <- vapply(raw[k + seq_len(k)], winner_of, character(1))
  # Map both orderings onto "a wins", "b wins", or "tie"; disagreement is a tie.
  first <- ifelse(w_ab == "A", "a", ifelse(w_ab == "B", "b", ifelse(w_ab == "TIE", "tie", NA)))
  second <- ifelse(w_ba == "A", "b", ifelse(w_ba == "B", "a", ifelse(w_ba == "TIE", "tie", NA)))
  verdict <- ifelse(is.na(first) | is.na(second), NA_character_, ifelse(first == second, first, "tie"))
  details <- data.frame(prompt = prompts, reference = references, a = a, b = b,
                        first_pass = first, second_pass = second, verdict = verdict,
                        stringsAsFactors = FALSE)
  ok <- !is.na(verdict)
  n <- sum(ok)
  list(
    mode = "pairwise",
    summary = list(
      win_rate = if (n) mean(verdict[ok] == "a") else NA_real_,
      tie_rate = if (n) mean(verdict[ok] == "tie") else NA_real_,
      loss_rate = if (n) mean(verdict[ok] == "b") else NA_real_,
      position_consistency = if (n) mean(first[ok] == second[ok]) else NA_real_,
      n = n, unparsed = sum(!ok)
    ),
    details = details
  )
}

# Append to judge.json and record the latest summary in status.json.
record_judgement <- function(run, result) {
  path <- run_path(run, "judge.json")
  history <- if (file.exists(path)) read_json(path) else list()
  entry <- list(
    mode = result$mode, against = result$against, judge = result$judge, judged_at = result$judged_at,
    summary = result$summary,
    details = lapply(seq_len(nrow(result$details)), function(i) as.list(result$details[i, , drop = FALSE]))
  )
  history[[length(history) + 1]] <- entry
  write_json(history, path)
  st <- read_json(run_path(run, "status.json"))
  st$judge <- c(list(mode = result$mode, against = result$against, judge = result$judge, judged_at = result$judged_at),
                result$summary)
  write_json(st, run_path(run, "status.json"))
  invisible(path)
}

#' @export
print.dragon_judgement <- function(x, ...) {
  s <- x$summary
  if (identical(x$mode, "pairwise")) {
    cli::cli_text("{.strong {x$run}} vs {.strong {x$against}} on {s$n} prompt{?s}, judged by {x$judge}:")
    cli::cli_text("wins {.strong {round(100 * s$win_rate)}%} \u00b7 ties {round(100 * s$tie_rate)}% \u00b7 losses {round(100 * s$loss_rate)}% \u00b7 position-consistent {round(100 * s$position_consistency)}%")
  } else {
    cli::cli_text("{.strong {x$run}} scored {.strong {round(s$mean_score, 2)}} / 10 over {s$n} prompt{?s}, judged by {x$judge}.")
  }
  if (isTRUE(s$unparsed > 0)) cli::cli_alert_warning("{s$unparsed} judge repl{?y/ies} could not be parsed and were left out.")
  invisible(x)
}

# The latest entry of judge.json, shaped like a dragon_judge() result.
last_judgement <- function(run) {
  path <- run_path(run, "judge.json")
  if (!file.exists(path)) return(NULL)
  history <- read_json(path)
  if (!length(history)) return(NULL)
  entry <- history[[length(history)]]
  rows <- entry$details %||% list()
  cols <- unique(unlist(lapply(rows, names)))
  details <- as.data.frame(lapply(stats::setNames(cols, cols), function(nm) {
    vapply(rows, function(r) {
      v <- r[[nm]]
      if (is.null(v) || !length(v) || is.na(v[[1]])) NA_character_ else as.character(v[[1]])
    }, character(1))
  }), stringsAsFactors = FALSE)
  if ("score" %in% names(details)) details$score <- as.numeric(details$score)
  if ("verdict" %in% names(details)) details$verdict[is.na(details$verdict)] <- "unparsed"
  list(mode = entry$mode, against = entry$against, judge = entry$judge, judged_at = entry$judged_at,
       summary = entry$summary, details = details)
}
