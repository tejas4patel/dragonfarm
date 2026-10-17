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
