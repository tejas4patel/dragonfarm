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

# Which models may drive agents. Measured on 20 tool-use tasks (the right
# tool, valid arguments, the key values right): 0.5B 13, 1.5B 15, 3B 17, 7B
# 18 of 20. 3B and up are reliable enough; smaller models get the fixed
# workflows. A model of unknown size (a server or an outside model the user
# chose) is allowed.
agent_model_ok <- function(model) {
  size <- model_size_b(model)
  is.na(size) || size >= 3
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

agent_run <- function(goal, agent = "answer", model = NULL, max_steps = NULL, backend = dragon_backend(),
                      max_result_chars = 6000L) {
  check_string(goal, "goal")
  policy <- policy_current()
  if (is.null(policy$agents[[agent]])) cli::cli_abort("The policy has no agent called {.val {agent}}.")
  max_steps <- as.integer(max_steps %||% policy$budgets$max_steps %||% 10L)
  specs <- agent_tool_specs(agent, policy)
  target <- resolve_target(model %||% default_answer_model())
  if (!agent_model_ok(target$model)) {
    store_record_event("agent_run", agent, ok = FALSE, code = "AGENT_MODEL_TOO_SMALL", detail = list(goal = goal, model = target$model))
    return(list(answer = NA_character_, steps = list(), stopped = "AGENT_MODEL_TOO_SMALL"))
  }
  convo <- list(list(role = "system", content = agent_roles[[agent]] %||% "Use the tools to do what the user asks."),
                list(role = "user", content = goal))
  steps <- list()
  t0 <- Sys.time()
  finish <- function(answer, stopped) {
    store_record_event("agent_run", agent, ok = identical(stopped, "answered"), code = if (!identical(stopped, "answered")) stopped,
                       detail = list(goal = goal, steps = length(steps), tools = vapply(steps, `[[`, "", "tool")),
                       duration_ms = round(1000 * as.numeric(difftime(Sys.time(), t0, units = "secs"))))
    list(answer = answer, steps = steps, stopped = stopped)
  }
  for (i in seq_len(max_steps)) {
    out <- backend_generate(backend, target, list(convo), max_new_tokens = 600, temperature = 0, top_p = 1, tools = specs)[[1]]
    call <- parse_tool_call(out)
    if (is.null(call)) return(finish(trimws(out), "answered"))
    r <- tool_call(call$name, call$args, agent = agent)
    payload <- if (isTRUE(r$ok)) r$result else list(error = r$error, code = r$code)
    text <- as.character(jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null"))
    if (nchar(text) > max_result_chars) text <- paste0(substr(text, 1, max_result_chars), " ...")
    steps[[length(steps) + 1]] <- list(tool = call$name, args = call$args, ok = isTRUE(r$ok), code = r$code)
    convo <- c(convo, list(
      list(role = "assistant", content = "",
           tool_calls = list(list(type = "function", `function` = list(name = call$name, arguments = call$args)))),
      list(role = "tool", name = call$name, content = text)
    ))
  }
  finish(NA_character_, "BUDGET_EXHAUSTED")
}
