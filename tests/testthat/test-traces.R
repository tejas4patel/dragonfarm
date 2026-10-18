# An agent task's steps from the record, and the record as OpenTelemetry traces.

test_that("an agent task's tool calls are tied to it and shown as its steps", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  replies <- list('<tool_call>{"name": "list_document_sets", "arguments": {}}</tool_call>', "You have no sets.")
  testthat::local_mocked_bindings(
    resolve_target = function(x) list(model = "Qwen/Qwen2.5-7B-Instruct"),
    backend_generate = function(...) { out <- replies[[1]]; replies <<- replies[-1]; list(out) }
  )
  r <- dragonfarm:::agent_run("What sets do I have?", agent = "answer", model = "Qwen/Qwen2.5-7B-Instruct")
  dragonfarm:::tool_call("list_runs")                                   # a person's own call: not part of the task
  tr <- dragonfarm:::task_trace(r$task, runs)
  expect_equal(tr$kind, c("tool", "agent_run"))
  expect_equal(tr$name[1], "list_document_sets")
  expect_true(is.numeric(r$steps[[1]]$model_ms))
  run_ev <- dragonfarm:::store_events(10, kind = "agent_run", runs_dir = runs)
  d <- jsonlite::fromJSON(run_ev$detail[1], simplifyVector = FALSE)
  html <- as.character(dragonfarm:::agent_trace_view(d, runs))
  expect_match(html, "list_document_sets"); expect_match(html, "Model time"); expect_match(html, "done")
})

test_that("the record exports as OTLP JSON traces, with tool calls under their task", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  replies <- list('<tool_call>{"name": "list_document_sets", "arguments": {}}</tool_call>', "None.")
  testthat::local_mocked_bindings(
    resolve_target = function(x) list(model = "Qwen/Qwen2.5-7B-Instruct"),
    backend_generate = function(...) { out <- replies[[1]]; replies <<- replies[-1]; list(out) }
  )
  r <- dragonfarm:::agent_run("Sets?", agent = "answer", model = "Qwen/Qwen2.5-7B-Instruct")
  dragonfarm:::store_record_event("outbound", "api.anthropic.com", ok = FALSE, code = "NOT_ALLOWED")
  f <- withr::local_tempfile(fileext = ".json")
  dragonfarm:::store_export_otlp(f, days = 1, runs_dir = runs)
  x <- jsonlite::fromJSON(f, simplifyVector = FALSE)
  spans <- x$resourceSpans[[1]]$scopeSpans[[1]]$spans
  kinds <- vapply(spans, function(s) s$attributes[[1]]$value$stringValue, "")
  tool <- spans[[which(kinds == "tool")]]; root <- spans[[which(kinds == "agent_run")]]
  expect_equal(tool$traceId, root$traceId)
  expect_equal(tool$parentSpanId, root$spanId)
  expect_equal(nchar(root$traceId), 32); expect_equal(nchar(root$spanId), 16)
  blocked <- spans[[which(kinds == "outbound")]]
  expect_equal(blocked$status$code, 2L)
  expect_false(identical(blocked$traceId, root$traceId))
  expect_true(as.numeric(tool$endTimeUnixNano) >= as.numeric(tool$startTimeUnixNano))
  expect_true("export" %in% dragonfarm:::store_events(5, runs_dir = runs)$kind)
})
