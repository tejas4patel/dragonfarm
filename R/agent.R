# The agent loop (internal, first cut). An agent is a role in the policy: a
# list of tools it may call. The loop gives the model those tools' contracts,
# runs each tool call it makes through tool_call(agent = ), hands the result
# back, and stops when the model answers without calling a tool or the step
# budget runs out. Every tool call is in the event log; each run of the loop
# is too.

agent_roles <- list(
  answer = paste(
    "You answer the user's questions about their document sets, using only what the tools return.",
    "answer_question searches a set and writes a cited answer; search_documents returns the passages themselves.",
    "When you have what you need, reply to the user without calling a tool, keeping the citations like [1].",
    "If the documents do not cover the question, say that the documents do not cover it."
  ),
  ingestion = "You read the user's files and web pages into document sets with the tools, and report what was read and what could not be.",
  ops = "You report on the user's document sets and training runs using the tools.",
  trainer = paste(
    "You help the user turn a document set into a trained model with the tools: write practice questions,",
    "train on them, check the run, evaluate it. Training waits for the user's approval; say so when it does."
  ),
  supervisor = "You find out what the user's document sets and training runs hold, using the tools, and report it plainly."
)

# Which models may drive agents. The smallest size is set in the policy:
# 3B by default (20 tool-use tasks: 0.5B 13, 1.5B 15, 3B 17, 7B 18 right),
# more for an agent that must match its fixed workflow in the evaluation
# harness (the answer agent: 7B). A model of unknown size (a server or an
# outside model the user chose) is allowed.
agent_model_ok <- function(model, min_b = 3) {
  size <- model_size_b(model)
  is.na(size) || size >= min_b
}

agent_min_model_b <- function(agent = NULL, policy = policy_current()) {
  as.numeric(policy$agents[[agent %||% ""]]$min_model_b %||% policy$min_model_b$default %||% 3)
}

# Whether agents are on for this machine, and one plain sentence saying so.
agent_mode <- function(info = the$hardware) {
  model <- info$tier$model %||% default_answer_model()
  on <- agent_model_ok(model)
  list(on = on, model = model, message = if (on) {
    sprintf("Agents: on, driven by %s.", model)
  } else {
    paste0("Agents: off. They need a model of 3B or larger, and the one recommended for this machine is ", model,
           ". Everything still works through the fixed workflows. To turn agents on, pass a 3B or larger model, ",
           "connect a model server with dragon_backend_server(), or allow an outside model.")
  })
}

agent_tool_specs <- function(agent, policy = policy_current()) {
  reg <- tool_registry()
  names <- intersect(unlist(policy$agents[[agent]]$tools), names(reg))
  lapply(unname(reg[names]), function(t) {
    list(type = "function", `function` = list(name = t$name, description = t$description, parameters = t$input))
  })
}

# The first tool call in a reply, or NULL. Qwen-style models write
# <tool_call>{"name": ..., "arguments": {...}}</tool_call>; a bare JSON object
# with a "name" is accepted too.
parse_tool_call <- function(text) {
  m <- regmatches(text, regexec("<tool_call>\\s*(\\{.*?\\})\\s*</tool_call>", text, perl = TRUE))[[1]]
  js <- if (length(m) >= 2) m[2] else {
    m2 <- regmatches(text, regexec("^\\s*(\\{\\s*\"name\".*\\})\\s*$", text, perl = TRUE))[[1]]
    if (length(m2) >= 2) m2[2] else NA_character_
  }
  if (is.na(js)) return(NULL)
  x <- tryCatch(jsonlite::fromJSON(js, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(x$name) || !is.character(x$name)) return(NULL)
  args <- x$arguments %||% x$parameters %||% list()
  if (is.character(args)) args <- tryCatch(jsonlite::fromJSON(args, simplifyVector = FALSE), error = function(e) list())
  if (!length(args)) args <- stats::setNames(list(), character())
  list(name = x$name, args = args)
}

# Each task keeps a checkpoint (the conversation and the steps so far) in
# <runs>/agent_tasks/<task>.rds, rewritten after every step. If R is killed
# mid-task, agent_resume() carries on from the last finished step: tool
# calls already made are not made again (they may have trained a model or
# sent something out with a person's approval).
agent_tasks_dir <- function(runs_dir = dragon_runs_dir()) file.path(runs_dir, "agent_tasks")

agent_checkpoint_save <- function(task, runs_dir = dragon_runs_dir()) {
  dir.create(agent_tasks_dir(runs_dir), recursive = TRUE, showWarnings = FALSE)
  file <- file.path(agent_tasks_dir(runs_dir), paste0(task$id, ".rds"))
  tmp <- paste0(file, ".tmp")
  saveRDS(task, tmp)
  file.rename(tmp, file)
  invisible(file)
}

agent_checkpoint_load <- function(id, runs_dir = dragon_runs_dir()) {
  file <- file.path(agent_tasks_dir(runs_dir), paste0(id, ".rds"))
  if (!file.exists(file)) return(NULL)
  readRDS(file)
}

# Tasks that started but never finished (R was killed or crashed).
agent_tasks_unfinished <- function(runs_dir = dragon_runs_dir()) {
  files <- list.files(agent_tasks_dir(runs_dir), pattern = "[.]rds$", full.names = TRUE)
  tasks <- lapply(files, readRDS)
  tasks <- Filter(function(t) identical(t$status, "running"), tasks)
  data.frame(id = vapply(tasks, `[[`, "", "id"), agent = vapply(tasks, `[[`, "", "agent"),
             goal = vapply(tasks, `[[`, "", "goal"), steps = vapply(tasks, function(t) length(t$steps), 0L),
             started = vapply(tasks, `[[`, "", "started"))
}

agent_run <- function(goal, agent = "answer", model = NULL, max_steps = NULL, backend = dragon_backend(),
                      max_result_chars = 6000L) {
  check_string(goal, "goal")
  policy <- policy_current()
  if (is.null(policy$agents[[agent]])) cli::cli_abort("The policy has no agent called {.val {agent}}.")
  max_steps <- as.integer(max_steps %||% policy$budgets$max_steps %||% 10L)
  target <- resolve_target(model %||% default_answer_model())
  min_b <- agent_min_model_b(agent, policy)
  if (!agent_model_ok(target$model, min_b)) {
    store_record_event("agent_run", agent, ok = FALSE, code = "AGENT_MODEL_TOO_SMALL",
                       detail = list(goal = goal, model = target$model, min_model_b = min_b))
    return(list(answer = NA_character_, steps = list(), stopped = "AGENT_MODEL_TOO_SMALL"))
  }
  task <- list(id = sprintf("%s-%s", format(Sys.time(), "%Y%m%d-%H%M%S"), paste(sample(c(letters, 0:9), 6, TRUE), collapse = "")),
               goal = goal, agent = agent, model = target$model, max_steps = max_steps, status = "running",
               started = now_utc(), elapsed = 0,
               convo = list(list(role = "system", content = agent_roles[[agent]] %||% "Use the tools to do what the user asks."),
                            list(role = "user", content = goal)),
               steps = list())
  agent_checkpoint_save(task)
  agent_loop(task, target, backend, max_result_chars)
}

# Carry on with a task from its checkpoint. A finished task is not run again.
agent_resume <- function(id, backend = dragon_backend(), max_result_chars = 6000L) {
  task <- agent_checkpoint_load(id)
  if (is.null(task)) return(list(answer = NA_character_, steps = list(), stopped = "NOT_FOUND"))
  if (!identical(task$status, "running")) return(list(answer = task$answer %||% NA_character_, steps = task$steps, stopped = task$status, task = task$id))
  store_record_event("agent_resume", task$agent, ok = TRUE, detail = list(task = task$id, from_step = length(task$steps) + 1L))
  agent_loop(task, resolve_target(task$model), backend, max_result_chars)
}

agent_loop <- function(task, target, backend, max_result_chars) {
  specs <- agent_tool_specs(task$agent)
  t0 <- Sys.time()
  elapsed <- function() task$elapsed + as.numeric(difftime(Sys.time(), t0, units = "secs"))
  finish <- function(answer, stopped) {
    task$status <- stopped
    task$answer <- answer
    task$elapsed <- elapsed()
    agent_checkpoint_save(task)
    store_record_event("agent_run", task$agent, ok = identical(stopped, "answered"), code = if (!identical(stopped, "answered")) stopped,
                       detail = list(goal = task$goal, model = task$model, max_steps = task$max_steps, steps = length(task$steps),
                                     tools = vapply(task$steps, `[[`, "", "tool"), answer_hash = result_hash(answer), task = task$id),
                       duration_ms = round(1000 * task$elapsed))
    list(answer = answer, steps = task$steps, stopped = stopped, task = task$id)
  }
  while (length(task$steps) < task$max_steps) {
    out <- backend_generate(backend, target, list(task$convo), max_new_tokens = 600, temperature = 0, top_p = 1, tools = specs)[[1]]
    call <- parse_tool_call(out)
    if (is.null(call)) return(finish(trimws(out), "answered"))
    r <- tool_call(call$name, call$args, agent = task$agent)
    payload <- if (isTRUE(r$ok)) r$result else list(error = r$error, code = r$code)
    text <- as.character(jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null"))
    if (nchar(text) > max_result_chars) text <- paste0(substr(text, 1, max_result_chars), " ...")
    task$steps[[length(task$steps) + 1]] <- list(tool = call$name, args = call$args, ok = isTRUE(r$ok), code = r$code)
    task$convo <- c(task$convo, list(
      list(role = "assistant", content = "",
           tool_calls = list(list(type = "function", `function` = list(name = call$name, arguments = call$args)))),
      list(role = "tool", name = call$name, content = text)
    ))
    task$elapsed <- elapsed(); t0 <- Sys.time()
    agent_checkpoint_save(task)
  }
  finish(NA_character_, "BUDGET_EXHAUSTED")
}
