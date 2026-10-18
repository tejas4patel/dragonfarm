# Agent evaluation harness. A suite is a JSON file of tasks with fixed checks
# (inst/evals/). The agent and its playbook, the fixed workflow it would
# replace, do the same tasks and are graded by the same code: no model grades
# anything, and an agent never grades its own work. An agent path ships only
# if it ties or beats its playbook on the tasks both can do.

# Wording that means "the documents do not say".
decline_pattern <- paste0(
  "(do(es)?( not|n't)|did not|cannot|can't) (directly |explicitly |specifically )?(cover|mention|contain|provide|include|address|specify|state|say|find|answer|determine|tell)",
  "|not (covered|mentioned|provided|specified|stated|included|available|found)",
  "|no (information|mention|details)",
  "|none of the (provided |found |retrieved )?(documents|excerpts|sources|passages)( found| provided| retrieved)? (directly )?(mention|address|cover|contain|provide|say|state)"
)

# Read a suite: a bundled name ("policies") or a path to a JSON file.
eval_suite <- function(suite) {
  if (is.list(suite)) return(check_eval_suite(suite))
  check_string(suite, "suite")
  path <- if (file.exists(suite)) suite else system.file("evals", paste0(suite, ".json"), package = "dragonfarm")
  if (!nzchar(path)) {
    cli::cli_abort("There is no evaluation suite called {.val {suite}}.", class = "dragonfarm_error", code = "FILE_NOT_FOUND")
  }
  check_eval_suite(jsonlite::read_json(path, simplifyVector = FALSE))
}

check_eval_suite <- function(suite) {
  problems <- character()
  if (!is.character(suite$name) || !nzchar(suite$name)) problems <- c(problems, "the suite has no name")
  if (!length(suite$tasks)) problems <- c(problems, "the suite has no tasks")
  ids <- vapply(suite$tasks, function(t) t$id %||% "", "")
  if (any(!nzchar(ids))) problems <- c(problems, "every task needs an id")
  if (anyDuplicated(ids)) problems <- c(problems, sprintf("task ids repeat: %s", paste(unique(ids[duplicated(ids)]), collapse = ", ")))
  for (t in suite$tasks) {
    e <- t$expect
    if (!is.character(t$goal) || !nzchar(t$goal)) problems <- c(problems, sprintf("task %s has no goal", t$id %||% "?"))
    if (!length(e$all) && !isTRUE(e$declines) && !length(e$tools)) {
      problems <- c(problems, sprintf("task %s has no check (expect all, declines or tools)", t$id %||% "?"))
    }
    bad <- Filter(function(p) inherits(try(suppressWarnings(grepl(p, "", perl = TRUE)), silent = TRUE), "try-error"), unlist(e$all))
    if (length(bad)) problems <- c(problems, sprintf("task %s has an invalid pattern: %s", t$id, bad[[1]]))
  }
  if (length(problems)) {
    cli::cli_abort(c("The evaluation suite is not valid.", stats::setNames(problems, rep("x", length(problems)))),
                   class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  suite
}

# Grade one output against a task's checks. Fixed code, no model.
#   all:      every pattern must appear in the answer (case-insensitive)
#   declines: the answer must say the documents do not cover it
#   tools:    every named tool must have been called (agents only)
eval_grade <- function(expect, answer, tools = NULL) {
  answer <- if (length(answer) && !is.na(answer)) answer else ""
  ok <- nzchar(answer)
  for (p in unlist(expect$all)) ok <- ok && grepl(p, answer, ignore.case = TRUE, perl = TRUE)
  if (isTRUE(expect$declines)) ok <- ok && grepl(decline_pattern, answer, ignore.case = TRUE, perl = TRUE)
  if (length(expect$tools) && !is.null(tools)) ok <- ok && all(unlist(expect$tools) %in% tools)
  ok
}

# The fixed workflows an agent can be compared with. Each takes the task and
# the suite and returns the answer text.
eval_playbooks <- list(
  ask = function(task, suite, model) {
    docs <- dragon_documents_load(task$set %||% suite$set)
    dragon_ask(docs, task$goal, model = model)$answer
  }
)

# The goal as the agent sees it: the task plus the set to use, as a person
# would say it. A task with "set": "none" is not about one set.
eval_goal <- function(task, suite) {
  set <- task$set %||% suite$set
  if (is.null(set) || identical(set, "none")) return(task$goal)
  sprintf("%s (Use the document set %s.)", task$goal, set)
}

timed <- function(expr) {
  t0 <- Sys.time()
  value <- tryCatch(expr, error = function(e) structure(conditionMessage(e), class = "eval_error"))
  list(value = value, seconds = as.numeric(difftime(Sys.time(), t0, units = "secs")))
}

# Run a suite: the agent on every task, and the playbook on the tasks it can
# do. Returns one row per task and path, with a summary and the verdict
# attached, and records the summary in the catalogue.
agent_eval <- function(suite = "policies", model = NULL, agent = NULL, playbook = NULL, paths = c("agent", "playbook"),
                       max_steps = 6L, progress = interactive()) {
  suite <- eval_suite(suite)
  agent <- agent %||% suite$agent %||% "answer"
  playbook <- playbook %||% suite$playbook
  model <- model %||% default_answer_model()
  pb <- if (!is.null(playbook)) eval_playbooks[[playbook]]
  if (!is.null(playbook) && is.null(pb)) cli::cli_abort("There is no playbook called {.val {playbook}}.")
  rows <- list()
  for (task in suite$tasks) {
    has_playbook <- !is.null(pb) && !identical(task$playbook, "none")
    if ("agent" %in% paths) {
      r <- timed(agent_run(eval_goal(task, suite), agent = agent, model = model, max_steps = max_steps))
      failed <- inherits(r$value, "eval_error")
      tools <- if (failed) character() else vapply(r$value$steps, `[[`, "", "tool")
      answer <- if (failed) NA_character_ else r$value$answer
      rows[[length(rows) + 1]] <- data.frame(
        id = task$id, path = "agent", ok = !failed && eval_grade(task$expect, answer, tools),
        steps = length(tools), tools = paste(tools, collapse = ">"),
        stopped = if (failed) "ERROR" else r$value$stopped, seconds = r$seconds,
        answer = if (failed) as.character(r$value) else answer %||% NA_character_)
    }
    if ("playbook" %in% paths && has_playbook) {
      r <- timed(pb(task, suite, model))
      failed <- inherits(r$value, "eval_error")
      rows[[length(rows) + 1]] <- data.frame(
        id = task$id, path = "playbook", ok = !failed && eval_grade(task$expect, r$value),
        steps = NA_integer_, tools = "", stopped = if (failed) "ERROR" else "answered", seconds = r$seconds,
        answer = as.character(r$value))
    }
    if (progress) {
      done <- rows[vapply(rows, function(x) x$id == task$id, TRUE)]
      cli::cli_alert_info(paste0(task$id, ": ", paste(vapply(done, function(x) paste(x$path, if (x$ok) "right" else "wrong"), ""), collapse = ", ")))
    }
  }
  res <- do.call(rbind, rows)
  summary <- eval_summary(res)
  store_record_event("agent_eval", suite$name, ok = isTRUE(summary$ships),
                     detail = list(agent = agent, playbook = playbook, model = model, summary = summary))
  attr(res, "summary") <- summary
  class(res) <- c("dragon_agent_eval", class(res))
  res
}

# Grade saved answers again, for example after a check is corrected. No model
# runs; both paths are graded by the same code as before.
agent_eval_regrade <- function(res, suite = "policies") {
  suite <- eval_suite(suite)
  tasks <- stats::setNames(suite$tasks, vapply(suite$tasks, `[[`, "", "id"))
  res$ok <- vapply(seq_len(nrow(res)), function(i) {
    tools <- if (res$path[i] == "agent") strsplit(res$tools[i], ">", fixed = TRUE)[[1]]
    !identical(res$stopped[i], "ERROR") && eval_grade(tasks[[res$id[i]]]$expect, res$answer[i], tools)
  }, TRUE)
  attr(res, "summary") <- eval_summary(res)
  res
}

# Success, time and steps per path, and the verdict on the tasks both did.
eval_summary <- function(res) {
  a <- res[res$path == "agent", ]
  p <- res[res$path == "playbook", ]
  both <- intersect(a$id, p$id)
  agent_both <- sum(a$ok[a$id %in% both])
  playbook_both <- sum(p$ok[p$id %in% both])
  list(
    tasks = length(unique(res$id)),
    agent_right = sum(a$ok), agent_tasks = nrow(a),
    playbook_right = sum(p$ok), playbook_tasks = nrow(p),
    shared_tasks = length(both), agent_right_shared = agent_both, playbook_right_shared = playbook_both,
    agent_median_seconds = if (nrow(a)) stats::median(a$seconds) else NA_real_,
    playbook_median_seconds = if (nrow(p)) stats::median(p$seconds) else NA_real_,
    agent_mean_steps = if (nrow(a)) mean(a$steps) else NA_real_,
    agent_stopped = if (nrow(a)) as.list(table(a$stopped)) else list(),
    ships = if (length(both)) agent_both >= playbook_both else NA
  )
}

#' @export
print.dragon_agent_eval <- function(x, ...) {
  s <- attr(x, "summary")
  cli::cli_text("{s$tasks} task{?s}. Agent right {s$agent_right} of {s$agent_tasks}; playbook right {s$playbook_right} of {s$playbook_tasks}.")
  if (s$shared_tasks) {
    cli::cli_text("On the {s$shared_tasks} tasks both did: agent {s$agent_right_shared}, playbook {s$playbook_right_shared}. ",
                  if (isTRUE(s$ships)) "The agent ties or beats the playbook." else "The agent does not match the playbook.")
  }
  cli::cli_text("Median seconds: agent {round(s$agent_median_seconds, 1)}, playbook {round(s$playbook_median_seconds, 1)}. Agent steps on average: {round(s$agent_mean_steps, 1)}.")
  invisible(x)
}
