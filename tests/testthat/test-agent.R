# The agent loop with a scripted model: tool call, result handed back, answer.

test_that("tool calls are parsed from Qwen-style and bare JSON replies", {
  p <- dragonfarm:::parse_tool_call
  x <- p('<tool_call>\n{"name": "search_documents", "arguments": {"set": "kb", "query": "warranty"}}\n</tool_call>')
  expect_equal(x$name, "search_documents")
  expect_equal(x$args$set, "kb")
  expect_equal(p('{"name": "list_runs", "arguments": {}}')$name, "list_runs")
  expect_equal(p('{"name": "list_runs", "arguments": "{\\"limit\\": 3}"}')$args$limit, 3L)
  expect_null(p("The warranty is two years [1]."))
  expect_null(p("<tool_call>not json</tool_call>"))
})

test_that("the loop runs the model's tool calls through tool_call() and stops at an answer", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  seen <- list()
  replies <- list('<tool_call>{"name": "list_document_sets", "arguments": {}}</tool_call>',
                  '<tool_call>{"name": "read_documents", "arguments": {"paths": ["x.pdf"], "name": "x"}}</tool_call>',
                  "You have no document sets yet.")
  testthat::local_mocked_bindings(
    resolve_target = function(x) list(model = "Qwen/Qwen2.5-7B-Instruct"),
    backend_generate = function(backend, target, conversations, ..., tools = NULL) {
      seen[[length(seen) + 1]] <<- list(convo = conversations[[1]], tools = vapply(tools, function(t) t$`function`$name, ""))
      out <- replies[[1]]; replies <<- replies[-1]; list(out)
    }
  )
  r <- dragonfarm:::agent_run("What sets do I have?", agent = "answer", model = "Qwen/Qwen2.5-7B-Instruct")
  expect_equal(r$stopped, "answered")
  expect_equal(r$answer, "You have no document sets yet.")
  expect_equal(vapply(r$steps, `[[`, "", "tool"), c("list_document_sets", "read_documents"))
  expect_equal(r$steps[[2]]$code, "NOT_ALLOWED")                       # the answer agent may not read documents
  expect_setequal(seen[[1]]$tools, c("list_document_sets", "search_documents", "answer_question"))
  last <- seen[[3]]$convo
  expect_equal(vapply(last, `[[`, "", "role"), c("system", "user", "assistant", "tool", "assistant", "tool"))
  expect_match(last[[6]]$content, "NOT_ALLOWED")                       # the refusal is handed back to the model
  ev <- dragonfarm:::store_events(runs_dir = runs)
  expect_true("agent_run" %in% ev$kind)

  replies <- rep(list('<tool_call>{"name": "list_runs", "arguments": {}}</tool_call>'), 5)
  r2 <- dragonfarm:::agent_run("Loop for ever", agent = "ops", model = "x", max_steps = 3)
  expect_equal(r2$stopped, "BUDGET_EXHAUSTED")
  expect_length(r2$steps, 3)
})

test_that("only models of 3B and up drive agents, and the mode is said plainly", {
  expect_true(dragonfarm:::agent_model_ok("Qwen/Qwen2.5-7B-Instruct"))
  expect_true(dragonfarm:::agent_model_ok("Qwen/Qwen2.5-3B-Instruct"))
  expect_false(dragonfarm:::agent_model_ok("Qwen/Qwen2.5-1.5B-Instruct"))
  expect_true(dragonfarm:::agent_model_ok("my-server-model"))          # unknown size: the user's choice
  on <- dragonfarm:::agent_mode(list(tier = list(model = "Qwen/Qwen2.5-7B-Instruct")))
  expect_true(on$on); expect_match(on$message, "Agents: on")
  off <- dragonfarm:::agent_mode(list(tier = list(model = "Qwen/Qwen2.5-1.5B-Instruct")))
  expect_false(off$on); expect_match(off$message, "fixed workflows")

  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  called <- FALSE
  testthat::local_mocked_bindings(backend_generate = function(...) { called <<- TRUE; list("x") })
  r <- dragonfarm:::agent_run("What sets do I have?", model = "Qwen/Qwen2.5-0.5B-Instruct")
  expect_equal(r$stopped, "AGENT_MODEL_TOO_SMALL")
  expect_false(called)                                                 # the small model is never asked
  expect_equal(dragonfarm:::store_events(runs_dir = runs)$code[1], "AGENT_MODEL_TOO_SMALL")
})

test_that("the policy sets the smallest model per agent: 7B for answer, 3B otherwise", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  pol <- dragonfarm:::policy_default()
  expect_equal(dragonfarm:::agent_min_model_b("answer", pol), 7)
  expect_equal(dragonfarm:::agent_min_model_b("ops", pol), 3)
  testthat::local_mocked_bindings(backend_generate = function(...) list("All done."))
  r <- dragonfarm:::agent_run("How long is the return window?", agent = "answer", model = "Qwen/Qwen2.5-3B-Instruct")
  expect_equal(r$stopped, "AGENT_MODEL_TOO_SMALL")
  r <- dragonfarm:::agent_run("Which runs failed?", agent = "ops", model = "Qwen/Qwen2.5-3B-Instruct")
  expect_equal(r$stopped, "answered")
  bad <- pol; bad$agents$answer$min_model_b <- "big"
  expect_match(dragonfarm:::policy_problems(bad), "min_model_b for 'answer'")
})

test_that("a task killed mid-way resumes from its checkpoint without repeating tool calls", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  calls <- character()
  replies <- list('<tool_call>{"name": "list_document_sets", "arguments": {}}</tool_call>', "CRASH",
                  '<tool_call>{"name": "search_documents", "arguments": {"set": "kb", "query": "warranty"}}</tool_call>',
                  "Two years [1].")
  seen <- list()
  testthat::local_mocked_bindings(
    resolve_target = function(x) list(model = "Qwen/Qwen2.5-7B-Instruct"),
    backend_generate = function(backend, target, conversations, ..., tools = NULL) {
      seen[[length(seen) + 1]] <<- conversations[[1]]
      out <- replies[[1]]; replies <<- replies[-1]
      if (identical(out, "CRASH")) stop("R was killed")
      list(out)
    },
    tool_call = function(name, args, agent = NULL, ...) { calls <<- c(calls, name); list(ok = TRUE, result = list(n = 0)) }
  )
  expect_error(dragonfarm:::agent_run("How long is the warranty?", agent = "answer", model = "Qwen/Qwen2.5-7B-Instruct"), "killed")
  open <- dragonfarm:::agent_tasks_unfinished(runs)
  expect_equal(nrow(open), 1)
  expect_equal(open$steps, 1)
  r <- dragonfarm:::agent_resume(open$id)
  expect_equal(r$stopped, "answered")
  expect_equal(r$answer, "Two years [1].")
  expect_equal(calls, c("list_document_sets", "search_documents"))     # the first call was not made again
  expect_equal(vapply(r$steps, `[[`, "", "tool"), c("list_document_sets", "search_documents"))
  expect_equal(vapply(seen[[3]], `[[`, "", "role"), c("system", "user", "assistant", "tool"))   # resumed with the first result
  expect_equal(nrow(dragonfarm:::agent_tasks_unfinished(runs)), 0)
  again <- dragonfarm:::agent_resume(open$id)                          # a finished task is not run again
  expect_equal(again$stopped, "answered")
  expect_equal(calls, c("list_document_sets", "search_documents"))
  ev <- dragonfarm:::store_events(runs_dir = runs)
  expect_true(all(c("agent_resume", "agent_run") %in% ev$kind))
  expect_equal(dragonfarm:::agent_resume("nope")$stopped, "NOT_FOUND")
})

test_that("the policy can route an agent to its own model", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  pol <- dragonfarm:::policy_default()
  pol$agents$answer$model <- "Qwen/Qwen2.5-14B-Instruct"
  dragonfarm:::policy_set(pol, set_by = "test", runs_dir = runs)
  used <- NULL
  testthat::local_mocked_bindings(
    resolve_target = function(x) { used <<- x; list(model = x) },
    backend_generate = function(...) list("Done.")
  )
  dragonfarm:::agent_run("Hi", agent = "answer")
  expect_equal(used, "Qwen/Qwen2.5-14B-Instruct")
  dragonfarm:::agent_run("Hi", agent = "answer", model = "Qwen/Qwen2.5-7B-Instruct")   # the caller's choice wins
  expect_equal(used, "Qwen/Qwen2.5-7B-Instruct")
  pol$agents$answer$model <- 7
  expect_match(dragonfarm:::policy_problems(pol), "model for 'answer'")
})

test_that("agent_route falls back to the fixed workflow and records why", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  replies <- list("Thirty days [1].")
  testthat::local_mocked_bindings(
    resolve_target = function(x) list(model = x),
    backend_generate = function(...) { out <- replies[[1]]; replies <<- replies[-1]; if (identical(out, "BOOM")) stop("worker died"); list(out) }
  )
  pb <- function() "From the playbook."
  r <- dragonfarm:::agent_route("How long?", "answer", pb, model = "Qwen/Qwen2.5-7B-Instruct")
  expect_equal(r$path, "agent")
  expect_equal(r$answer, "Thirty days [1].")
  small <- dragonfarm:::agent_route("How long?", "answer", pb, model = "Qwen/Qwen2.5-1.5B-Instruct")
  expect_equal(small$path, "playbook")
  expect_equal(small$reason, "AGENT_MODEL_TOO_SMALL")
  expect_equal(small$answer, "From the playbook.")
  replies <- list("BOOM")
  err <- dragonfarm:::agent_route("How long?", "answer", pb, model = "Qwen/Qwen2.5-7B-Instruct")
  expect_equal(err$reason, "ERROR")
  replies <- as.list(rep('<tool_call>{"name": "list_document_sets", "arguments": {}}</tool_call>', 3))
  out <- dragonfarm:::agent_route("How long?", "answer", pb, model = "Qwen/Qwen2.5-7B-Instruct", max_steps = 2)
  expect_equal(out$reason, "BUDGET_EXHAUSTED")
  rate <- dragonfarm:::agent_fallback_rate(7, runs)
  expect_equal(rate$routed, 4)
  expect_equal(rate$fell_back, 3)
  expect_equal(sort(names(rate$reasons)), c("AGENT_MODEL_TOO_SMALL", "BUDGET_EXHAUSTED", "ERROR"))
  expect_equal(dragonfarm:::store_summary(7, runs)$agents$fell_back, 3)
})
