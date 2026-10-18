test_that("the bundled suite loads and every task has a check", {
  s <- dragonfarm:::eval_suite("policies")
  expect_equal(s$name, "policies")
  expect_gte(length(s$tasks), 15)
  expect_error(dragonfarm:::eval_suite("no-such-suite"), class = "dragonfarm_error")
})

test_that("a suite with a missing check or a bad pattern is refused", {
  bad <- list(name = "x", tasks = list(list(id = "a", goal = "Q?", expect = list()),
                                       list(id = "a", goal = "Q?", expect = list(all = list("(unclosed")))))
  err <- tryCatch(dragonfarm:::eval_suite(bad), error = function(e) e)
  expect_s3_class(err, "dragonfarm_error")
  msg <- conditionMessage(err)
  expect_match(msg, "no check"); expect_match(msg, "repeat"); expect_match(msg, "invalid pattern")
})

test_that("grading is fixed code: patterns, declines, tools", {
  g <- dragonfarm:::eval_grade
  expect_true(g(list(all = list("30 days")), "Returns are accepted within 30 Days [1]."))
  expect_false(g(list(all = list("30 days", "label")), "Within 30 days."))
  expect_true(g(list(declines = TRUE), "The documents do not mention a price."))
  expect_false(g(list(declines = TRUE), "It costs $99."))
  # Declines a 3B wrote that the first pattern missed.
  expect_true(g(list(declines = TRUE), "None of the passages found mention the cost of the Sentry doorbell."))
  expect_true(g(list(declines = TRUE), "None of the found documents contain the specific information about the support phone number."))
  expect_false(g(list(all = list("x")), NA_character_))
  expect_true(g(list(all = list("policies"), tools = list("list_document_sets")), "You have: policies", tools = "list_document_sets"))
  expect_false(g(list(all = list("policies"), tools = list("list_document_sets")), "You have: policies", tools = character()))
})

test_that("agent_eval runs both paths, grades them alike, and records the verdict", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  suite <- list(name = "mini", agent = "answer", playbook = "ask", set = "s", tasks = list(
    list(id = "known", goal = "How long?", expect = list(all = list("30 days"))),
    list(id = "uncovered", goal = "Price?", expect = list(declines = TRUE)),
    list(id = "sets", goal = "Which sets?", set = "none", playbook = "none",
         expect = list(all = list("s"), tools = list("list_document_sets")))
  ))
  goals <- character()
  testthat::local_mocked_bindings(
    agent_run = function(goal, ...) {
      goals <<- c(goals, goal)
      if (grepl("Which sets", goal)) return(list(answer = "You have s.", steps = list(list(tool = "list_document_sets")), stopped = "answered"))
      if (grepl("Price", goal)) return(list(answer = "It is $5.", steps = list(list(tool = "answer_question")), stopped = "answered"))
      list(answer = "30 days [1]", steps = list(list(tool = "answer_question")), stopped = "answered")
    },
    dragon_documents_load = function(...) "docs",
    dragon_ask = function(docs, question, ...) list(answer = if (grepl("Price", question)) "The documents do not cover prices." else "30 days [1]")
  )
  res <- dragonfarm:::agent_eval(suite, model = "Qwen/Qwen2.5-7B-Instruct", progress = FALSE)
  expect_equal(nrow(res), 5)                                       # the tool task has no playbook
  expect_equal(goals[1], "How long? (Use the document set s.)")
  expect_equal(goals[3], "Which sets?")
  s <- attr(res, "summary")
  expect_equal(c(s$agent_right, s$playbook_right), c(2, 2))
  expect_equal(c(s$agent_right_shared, s$playbook_right_shared), c(1, 2))
  expect_false(s$ships)                                            # the agent missed the decline
  ev <- dragonfarm:::store_events(runs_dir = runs)
  expect_true("agent_eval" %in% ev$kind)
  expect_message(print(res), "does not match")
})

test_that("saved answers can be graded again without running a model", {
  expect_true(dragonfarm:::eval_grade(list(declines = TRUE), "None of the documents mention the cost of the doorbell."))
  res <- data.frame(id = c("not-price", "not-price", "return-window"), path = c("agent", "playbook", "agent"), ok = FALSE,
                    steps = c(1, NA, 1), tools = c("search_documents", "", "list_document_sets"), stopped = "answered",
                    seconds = 1, answer = c("None of the provided documents mention the cost.", "The documents do not cover prices.",
                                            "What would you like to know?"))
  r <- dragonfarm:::agent_eval_regrade(res, "policies")
  expect_equal(r$ok, c(TRUE, TRUE, FALSE))
  expect_true(attr(r, "summary")$ships)
})
