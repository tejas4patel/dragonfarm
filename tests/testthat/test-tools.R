# Tool contracts (inst/tools/*.json) and the dispatcher, with the heavy
# functions mocked. Agents will see only these contracts.

tool_hits <- function(n = 3) {
  data.frame(n = seq_len(n), id = sprintf("abc-%03d", seq_len(n) - 1), source = "policy.pdf", section = "Returns",
             text = "Any device can be returned within 30 days.", score = 0.8, similarity = 0.8, weight = 1,
             stringsAsFactors = FALSE)
}

test_that("every tool contract is well formed and has an implementation", {
  dir <- system.file("tools", package = "dragonfarm")
  files <- setdiff(list.files(dir, pattern = "[.]json$"), "error_codes.json")
  expect_gte(length(files), 5)
  tools <- dragonfarm:::tool_registry(refresh = TRUE)
  expect_equal(length(tools), length(files))
  expect_false(anyDuplicated(names(tools)) > 0)
  for (f in files) {
    tool <- jsonlite::fromJSON(file.path(dir, f), simplifyVector = FALSE)
    expect_equal(dragonfarm:::tool_contract_problems(tool, f), character(), label = f)
  }
})

test_that("arguments are checked against the contract before anything runs", {
  schema <- dragonfarm:::tool_registry()[["search_documents"]]$input
  sp <- function(args) dragonfarm:::schema_problems(args, schema)
  expect_equal(sp(list(set = "kb", query = "warranty")), character())
  expect_match(sp(list(query = "warranty")), "input.set is required")
  expect_match(sp(list(set = "kb", query = "")), "input.query must not be empty")
  expect_match(sp(list(set = "kb", query = "q", k = 0)), "input.k must be at least 1")
  expect_match(sp(list(set = "kb", query = "q", k = 2.5)), "input.k must be integer")
  expect_match(sp(list(set = "kb", query = "q", method = "fuzzy")), "must be one of hybrid, dense")
  expect_match(sp(list(set = "kb", query = "q", rm = TRUE)), "input.rm is not allowed")
  filled <- dragonfarm:::with_defaults(list(set = "kb", query = "q"), schema)
  expect_equal(filled[c("k", "extra", "method")], list(k = 4L, extra = 0L, method = "hybrid"))

  res <- dragonfarm:::tool_call("search_documents", list(set = "kb"))
  expect_false(res$ok)
  expect_equal(res$code, "INVALID_ARGUMENTS")
  expect_equal(dragonfarm:::tool_call("no_such_tool")$code, "INVALID_ARGUMENTS")
})

test_that("search and answer return what their contracts promise", {
  f <- write_fake_set()
  docs <- dragon_documents_load(f$dir)
  seen <- NULL
  testthat::local_mocked_bindings(
    dragon_documents_load = function(dir, ...) docs,
    dragon_retrieve = function(docs, query, k = 4, method = "hybrid", extra = 0) {
      seen <<- list(k = k, extra = extra, method = method)
      h <- tool_hits(3); h$page <- c(2L, NA, NA); h
    },
    dragon_ask = function(docs, question, model = NULL, k = 4, compare = FALSE, ...) {
      structure(list(question = question, answer = "Thirty days [1].", model = "test-model", documents = "kb",
                     sources = transform(tool_hits(2), page = NA_integer_, cited = c(TRUE, FALSE))), class = "dragon_answer")
    }
  )
  reg <- dragonfarm:::tool_registry()
  s <- dragonfarm:::tool_call("search_documents", list(set = "kb", query = "warranty", extra = 2))
  expect_true(s$ok)
  expect_equal(seen, list(k = 4L, extra = 2L, method = "hybrid"))
  expect_equal(dragonfarm:::schema_problems(s$result, reg$search_documents$output, "output"), character())
  expect_null(s$result[[2]]$page)                              # NA becomes null, as the schema allows

  a <- dragonfarm:::tool_call("answer_question", list(set = "kb", question = "How long?", compare = TRUE))
  expect_true(a$ok)
  expect_equal(a$result$answer, "Thirty days [1].")
  expect_equal(dragonfarm:::schema_problems(a$result, reg$answer_question$output, "output"), character())
})

test_that("failures come back as typed codes, never as thrown errors", {
  withr::local_options(dragonfarm.runs_dir = tempfile("runs-"))
  expect_equal(dragonfarm:::tool_call("search_documents", list(set = "missing", query = "q"))$code, "NOT_A_SET")
  expect_equal(dragonfarm:::tool_call("run_status", list(run = "missing"))$code, "NOT_A_RUN")
  testthat::local_mocked_bindings(
    dragon_documents_load = function(dir, ...) structure(list(name = "kb"), class = "dragon_documents"),
    dragon_ask = function(...) rlang::abort("The inference worker reported an error.", class = "dragonfarm_error",
                                            code = "OUT_OF_MEMORY")
  )
  r <- dragonfarm:::tool_call("answer_question", list(set = "kb", question = "q"))
  expect_false(r$ok)
  expect_equal(r$code, "OUT_OF_MEMORY")
  expect_equal(dragonfarm:::tool_call("list_document_sets")$result, list())   # an empty runs folder lists nothing
})

test_that("read_documents reads a set, records its version, and codes a missing path", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  missing <- dragonfarm:::tool_call("read_documents", list(paths = file.path(runs, "nope.pdf"), name = "x"))
  expect_equal(missing$code, "FILE_NOT_FOUND")

  f <- write_fake_set(root = runs)
  docs <- dragon_documents_load(f$dir)
  testthat::local_mocked_bindings(dragon_documents = function(paths, name = NULL, ...) docs)
  r <- dragonfarm:::tool_call("read_documents", list(paths = list("a.pdf", "b.md"), name = "kb"))
  expect_true(r$ok)
  expect_equal(r$result$version, 1L)
  expect_equal(r$result$failed[[1]]$name, "bad.docx")              # the fake set has one unreadable source
  expect_equal(dragonfarm:::schema_problems(r$result, dragonfarm:::tool_registry()$read_documents$output, "output"), character())
  r2 <- dragonfarm:::tool_call("read_documents", list(paths = "a.pdf", name = "kb"))   # a single path from R is a list of one
  expect_true(r2$ok)
  expect_equal(r2$result$version, 1L)                               # nothing changed: same version
})

test_that("agents are held to the policy; people acting directly are not", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  pol <- dragonfarm:::policy_current()
  expect_equal(pol$version, 1L)
  expect_equal(dragonfarm:::policy_problems(pol), character())

  # an agent calling a tool outside its list is refused, and the refusal is recorded
  r <- dragonfarm:::tool_call("read_documents", list(paths = "x.pdf", name = "x"), agent = "answer")
  expect_equal(r$code, "NOT_ALLOWED")
  # writes need approval once the policy says so; the request is recorded, nothing runs
  pol2 <- pol; pol2$approvals$side_effects <- list("writes", "irreversible", "outbound")
  expect_equal(dragonfarm:::policy_set(pol2, set_by = "admin"), 2L)
  r2 <- dragonfarm:::tool_call("read_documents", list(paths = "x.pdf", name = "x"), agent = "ingestion")
  expect_equal(r2$code, "NEEDS_APPROVAL")
  ev <- dragonfarm:::store_events(runs_dir = runs)
  expect_true("approval_request" %in% ev$kind)
  expect_true("policy_set" %in% ev$kind)
  # a person calling directly is not held (here the path is missing, so it fails on its own terms)
  expect_equal(dragonfarm:::tool_call("read_documents", list(paths = "x.pdf", name = "x"))$code, "FILE_NOT_FOUND")
  # an allowed read-only call goes through for the agent
  expect_equal(dragonfarm:::tool_call("list_document_sets", agent = "answer")$ok, TRUE)

  # policy versions cannot be edited, and a broken policy is refused
  con <- dragonfarm:::store_open(runs)
  expect_error(DBI::dbExecute(con, "DELETE FROM policies"), "append-only")
  bad <- pol; bad$agents$answer$tools <- list("make_coffee")
  expect_error(dragonfarm:::policy_set(bad), "unknown tool 'make_coffee'")
  expect_equal(dragonfarm:::policy_current()$version, 2L)
})
