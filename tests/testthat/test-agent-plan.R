# An agent task's plan before it starts (U2): the envelope it works in.

test_that("the plan lists the tools, what each does, and which wait for a person", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  p <- dragonfarm:::agent_plan("Train a model on the kb set", agent = "trainer", runs_dir = runs)
  expect_s3_class(p, "dragon_agent_plan")
  expect_true(all(c("train_model", "promote_model", "list_runs") %in% p$tools$tool))
  expect_true(p$tools$waits[p$tools$tool == "train_model"])             # training waits for a person (D-8)
  expect_false(p$tools$waits[p$tools$tool == "list_runs"])
  expect_equal(p$tools$side_effect[p$tools$tool == "list_runs"], "read_only")
  expect_equal(p$max_steps, 30L); expect_equal(p$min_model_b, 3)
  txt <- dragonfarm:::agent_plan_text(p)
  expect_true(any(grepl("Waits for a person before: .*train_model", txt)))
  expect_true(any(grepl("at most 30 steps and 120 GPU minutes", txt, fixed = TRUE)))
  expect_true(any(grepl("No such task has run here before", txt, fixed = TRUE)))
  expect_output(print(p), "It may use:")
  expect_error(dragonfarm:::agent_plan("x", agent = "nobody", runs_dir = runs), "no agent called")
})

test_that("the plan follows the policy: tools taken away, approvals added", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  pol <- dragonfarm:::policy_current(runs); pol$version <- NULL
  pol$agents$answer$tools <- list("list_document_sets", "search_documents")
  pol$approvals$tools <- c(unlist(pol$approvals$tools), "search_documents")
  dragonfarm:::policy_set(pol, set_by = "admin", note = "tighter", runs_dir = runs)
  p <- dragonfarm:::agent_plan("What does the policy say?", agent = "answer", runs_dir = runs)
  expect_setequal(p$tools$tool, c("list_document_sets", "search_documents"))
  expect_true(p$tools$waits[p$tools$tool == "search_documents"])
  expect_equal(p$policy_version, 2L)
  expect_equal(p$min_model_b, 7)
})

test_that("past tasks give a time and step estimate", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  for (x in list(c(4000, 2), c(6000, 4), c(99000, 30))) {
    ok <- x[2] < 30
    dragonfarm:::store_record_event("agent_run", "ops", ok = ok, detail = list(steps = x[2]), duration_ms = x[1], runs_dir = runs)
  }
  p <- dragonfarm:::agent_plan("How are my runs?", agent = "ops", runs_dir = runs)
  expect_equal(p$past, 2L); expect_equal(p$estimate_s, 5); expect_equal(p$typical_steps, 3)   # the failed task is left out
  expect_true(any(grepl("Before: 2 such tasks here, typically about 5 s and 3 steps.", dragonfarm:::agent_plan_text(p), fixed = TRUE)))
})

test_that("an agent task records its plan, so the record shows what it was allowed", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  testthat::local_mocked_bindings(
    resolve_target = function(x) list(model = "Qwen/Qwen2.5-7B-Instruct"),
    backend_generate = function(backend, target, conversations, ..., tools = NULL) list("Nothing to do.")
  )
  r <- dragonfarm:::agent_run("Say hello", agent = "ops", model = "Qwen/Qwen2.5-7B-Instruct")
  expect_equal(r$stopped, "answered")
  d <- jsonlite::fromJSON(dragonfarm:::store_events(1, kind = "agent_run", runs_dir = runs)$detail)
  expect_setequal(d$plan$tools, c("list_document_sets", "list_runs", "run_status"))
  expect_equal(d$plan$max_steps, 30L)
})

test_that("the trace view shows what the task was allowed", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  d <- list(goal = "Train", model = "m", model_ms = 1000, task = "t1",
            plan = list(tools = list("list_runs", "train_model"), waits = list("train_model"), max_steps = 30))
  html <- as.character(dragonfarm:::agent_trace_view(d, runs))
  expect_match(html, "list_runs, train_model; at most 30 steps; waits for a person before train_model", fixed = TRUE)
  d$plan <- NULL
  expect_false(grepl("Allowed", as.character(dragonfarm:::agent_trace_view(d, runs))))   # older tasks have no plan
})
