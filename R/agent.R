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
# A model server, when one is set, is what drives agents; otherwise the model
# recommended for this machine's hardware (a CPU-only machine gets a small
# one, so agents are off there unless a server or larger model is chosen).
agent_mode <- function(info = the$hardware, backend = tryCatch(dragon_backend(), error = function(e) NULL)) {
  server <- !is.null(backend) && is_server_backend(backend)
  model <- if (server) backend$model else info$tier$model %||% default_answer_model()
  on <- agent_model_ok(model)
  list(on = on, model = model, server = server, message = if (on) {
    sprintf("Agents: on, driven by %s%s.", model, if (server) " on a model server" else "")
  } else {
    paste0("Agents: off. They need a model of 3B or larger, and ", if (server) "the model server runs " else
             "the one recommended for this machine is ", model,
           ". Everything still works through the fixed workflows. To turn agents on, choose a 3B or larger model, ",
           "connect a model server, or allow an outside model in Settings.")
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
  # Routing: the caller's model, else the one the policy names for this
  # agent, else the model recommended for this machine.
  target <- resolve_target(model %||% policy$agents[[agent]]$model %||% default_answer_model())
  # On a model server, the server's model is what answers, so that is the
  # one whose size counts.
  if (is_server_backend(backend)) target$model <- backend$model
  min_b <- agent_min_model_b(agent, policy)
  if (!agent_model_ok(target$model, min_b)) {
    store_record_event("agent_run", agent, ok = FALSE, code = "AGENT_MODEL_TOO_SMALL",
                       detail = list(goal = goal, model = target$model, min_model_b = min_b))
    return(list(answer = NA_character_, steps = list(), stopped = "AGENT_MODEL_TOO_SMALL"))
  }
  task <- list(id = sprintf("%s-%s", format(Sys.time(), "%Y%m%d-%H%M%S"), paste(sample(c(letters, 0:9), 6, TRUE), collapse = "")),
               goal = goal, agent = agent, model = target$model, max_steps = max_steps, status = "running",
               started = now_utc(), elapsed = 0,
               plan = tryCatch(agent_plan_record(agent_plan(goal, agent, target$model)), error = function(e) NULL),
               convo = list(list(role = "system", content = agent_roles[[agent]] %||% "Use the tools to do what the user asks."),
                            list(role = "user", content = goal)),
               steps = list())
  agent_checkpoint_save(task)
  agent_loop(task, target, backend, max_result_chars)
}

# What a task's record keeps of its plan: enough to compare what the agent
# was allowed to do with what it did.
agent_plan_record <- function(p) {
  list(tools = as.list(p$tools$tool), waits = as.list(p$tools$tool[p$tools$waits]), max_steps = p$max_steps,
       policy_version = p$policy_version)
}

# Carry on with a task from its checkpoint. A finished task is not run again.
agent_resume <- function(id, backend = dragon_backend(), max_result_chars = 6000L) {
  task <- agent_checkpoint_load(id)
  if (is.null(task)) return(list(answer = NA_character_, steps = list(), stopped = "NOT_FOUND"))
  if (!identical(task$status, "running")) return(list(answer = task$answer %||% NA_character_, steps = task$steps, stopped = task$status, task = task$id))
  store_record_event("agent_resume", task$agent, ok = TRUE, detail = list(task = task$id, from_step = length(task$steps) + 1L))
  target <- if (is_server_backend(backend)) list(model = backend$model) else resolve_target(task$model)
  agent_loop(task, target, backend, max_result_chars)
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
                                     tools = vapply(task$steps, `[[`, "", "tool"), answer_hash = result_hash(answer), task = task$id,
                                     model_ms = task$model_ms %||% 0, plan = task$plan),
                       duration_ms = round(1000 * task$elapsed))
    list(answer = answer, steps = task$steps, stopped = stopped, task = task$id)
  }
  while (length(task$steps) < task$max_steps) {
    tm <- Sys.time()
    out <- backend_generate(backend, target, list(task$convo), max_new_tokens = 600, temperature = 0, top_p = 1, tools = specs)[[1]]
    model_ms <- round(1000 * as.numeric(difftime(Sys.time(), tm, units = "secs")))
    task$model_ms <- (task$model_ms %||% 0) + model_ms
    call <- parse_tool_call(out)
    if (is.null(call)) return(finish(trimws(out), "answered"))
    r <- withr::with_options(list(dragonfarm.task = task$id), tool_call(call$name, call$args, agent = task$agent))
    payload <- if (isTRUE(r$ok)) r$result else list(error = r$error, code = r$code)
    text <- as.character(jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null"))
    if (nchar(text) > max_result_chars) text <- paste0(substr(text, 1, max_result_chars), " ...")
    task$steps[[length(task$steps) + 1]] <- list(tool = call$name, args = call$args, ok = isTRUE(r$ok), code = r$code, model_ms = model_ms)
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

# Run an agent, and when it cannot do the job, its fixed workflow instead.
# playbook is a function of no arguments returning the answer text (for the
# answer agent, dragon_ask() on the set). The agent is skipped when its
# model is too small; it falls back when it runs out of steps, answers
# nothing, or fails. Each fallback is recorded with its reason, so the
# fallback rate can be tracked (store_summary()).
agent_route <- function(goal, agent = "answer", playbook, model = NULL, ...) {
  r <- tryCatch(agent_run(goal, agent = agent, model = model, ...),
                error = function(e) list(answer = NA_character_, steps = list(), stopped = "ERROR", error = conditionMessage(e)))
  if (identical(r$stopped, "answered") && !is.na(r$answer) && nzchar(trimws(r$answer))) {
    return(list(answer = r$answer, path = "agent", reason = NULL, steps = r$steps, task = r$task))
  }
  reason <- if (identical(r$stopped, "answered")) "EMPTY_ANSWER" else r$stopped
  store_record_event("fallback", agent, ok = TRUE, code = reason,
                     detail = list(goal = goal, task = r$task, error = r$error))
  list(answer = playbook(), path = "playbook", reason = reason, steps = r$steps, task = r$task)
}

# Of the agent tasks routed in the last `days`, how many fell back.
agent_fallback_rate <- function(days = 7, runs_dir = dragon_runs_dir()) {
  con <- store_open(runs_dir)
  since <- format(Sys.time() - days * 86400, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  ev <- store_get(con, "SELECT kind, code FROM events WHERE at >= ? AND kind IN ('agent_run', 'fallback')", params = list(since))
  fell <- sum(ev$kind == "fallback")
  # Every agent run leaves an agent_run event, finished or not, except one
  # that failed with an error; those count from their fallback.
  ran <- sum(ev$kind == "agent_run") + sum(ev$kind == "fallback" & ev$code %in% "ERROR")
  list(routed = ran, fell_back = fell, reasons = table(ev$code[ev$kind == "fallback"]))
}
