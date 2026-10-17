# The tool contracts as ellmer tools.

test_that("every contract becomes an ellmer tool that goes through tool_call()", {
  skip_if_not_installed("ellmer")
  skip_if_not_installed("S7")
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  tools <- dragon_ellmer_tools()
  expect_setequal(names(tools), names(dragonfarm:::tool_registry()))
  s <- tools$search_documents
  expect_true(S7::S7_inherits(s, ellmer::ToolDef))
  expect_equal(S7::prop(s, "name"), "search_documents")
  expect_true(isTRUE(S7::prop(s, "annotations")$read_only_hint))
  expect_false(isTRUE(S7::prop(tools$read_documents, "annotations")$read_only_hint))
  expect_equal(names(formals(s)), c("set", "query", "k", "extra", "method"))

  # calling it runs the contract checks and returns a typed error, not a crash
  out <- jsonlite::fromJSON(s(set = "missing", query = "q"))       # JSON text, for MCP clients and models
  expect_equal(out$code, "NOT_A_SET")
  # as an agent, policy applies
  agent_tools <- dragon_ellmer_tools(agent = "answer")
  expect_equal(jsonlite::fromJSON(agent_tools$read_documents(paths = list("x.pdf"), name = "x"))$code, "NOT_ALLOWED")
  expect_equal(nrow(dragonfarm:::store_events(runs_dir = runs)), 2L)
  expect_equal(names(dragon_ellmer_tools(tools = "list_runs")), "list_runs")
  expect_error(dragon_ellmer_tools(tools = "make_coffee"), "No tool called")
})
