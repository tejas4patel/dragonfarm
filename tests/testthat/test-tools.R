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
  testthat::local_mocked_bindings(dragon_documents = function(paths, name = NULL, ...) {
    dragonfarm:::store_sync_set(dragonfarm:::store_open(), docs$name, docs$dir)   # as the real one does
    docs
  })
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

test_that("the teach, train, evaluate and cancel tools keep their contracts", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  f <- write_fake_set(root = runs, name = "kb")
  docs <- dragon_documents_load(f$dir)
  run <- structure(list(id = "20261017-0001-test", dir = file.path(runs, "20261017-0001-test")), class = "dragon_run")
  trained <- NULL; cancelled <- FALSE
  testthat::local_mocked_bindings(
    dragon_questions = function(docs, generator = NULL, n_per_chunk = 3, mix = TRUE, ...) {
      structure(data.frame(question = c("a?", "b?"), keep = c(TRUE, FALSE)), path = "/x/q.jsonl")
    },
    dragon_questions_load = function(path) structure(data.frame(question = "a?", keep = TRUE), class = c("dragon_questions", "data.frame")),
    dragon_questions_dataset = function(qa, ...) "dataset",
    hardware_info = function() list(device = "cuda", vram_gb = 8),
    dragon_train = function(dataset, model, args, hardware, name = NULL, wait = FALSE, ...) {
      trained <<- list(model = model, four_bit = hardware$load_in_4bit, gc = args$gradient_checkpointing); run
    },
    dragon_status = function(run) list(state = if (cancelled) "cancelled" else "running"),
    run_from = function(r) run,
    dragon_evaluate = function(run, ...) list(eval_loss = 0.5, perplexity = 1.65, samples = data.frame(prompt = 1:3)),
    dragon_cancel = function(run, ...) { cancelled <<- TRUE; invisible(run) }
  )
  reg <- dragonfarm:::tool_registry(refresh = TRUE)
  ok <- function(name, args) {
    r <- dragonfarm:::tool_call(name, args)
    expect_true(r$ok, label = name)
    expect_equal(dragonfarm:::schema_problems(r$result, reg[[name]]$output, "output"), character(), label = name)
    r$result
  }
  w <- ok("write_practice_questions", list(set = "kb"))
  expect_equal(c(w$n_pairs, w$n_kept), c(2L, 1L))
  t3 <- ok("train_model", list(questions = "/x/q.jsonl", model = "Qwen/Qwen2.5-3B-Instruct"))
  expect_true(t3$load_in_4bit)                              # a 3B on 8 GB trains in 4-bit ...
  expect_true(trained$gc)                                   # ... with gradient checkpointing
  t05 <- ok("train_model", list(questions = "/x/q.jsonl", model = "Qwen/Qwen2.5-0.5B-Instruct"))
  expect_false(t05$load_in_4bit)
  e <- ok("evaluate_run", list(run = "20261017-0001-test"))
  expect_equal(e$n_samples, 3L)
  ok("cancel_run", list(run = "20261017-0001-test"))
  expect_true(cancelled)
  # an agent asking to train waits for a person
  expect_equal(dragonfarm:::tool_call("train_model", list(questions = "/x/q.jsonl", model = "m"), agent = "trainer")$code, "NEEDS_APPROVAL")
})

test_that("a missing question file is FILE_NOT_FOUND", {
  withr::local_options(dragonfarm.runs_dir = tempfile("runs-"))
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  expect_equal(dragonfarm:::tool_call("train_model", list(questions = "nope.jsonl", model = "m"))$code, "FILE_NOT_FOUND")
})

test_that("search_documents can search one document of a set", {
  f <- write_fake_set()
  withr::local_options(dragonfarm.runs_dir = f$root)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  docs <- dragon_documents_load(f$dir)
  seen <- NULL
  testthat::local_mocked_bindings(
    dragon_documents_load = function(dir, ...) docs,
    dragon_retrieve = function(docs, query, k = 4, method = "hybrid", extra = 0) {
      seen <<- k
      # the whole set ranked: NEWS.md first, then the two policy.pdf excerpts
      data.frame(n = 1:3, id = c("def-000", "abc-001", "abc-000"), source = c("NEWS.md", "policy.pdf", "policy.pdf"),
                 section = "s", text = c("Changed.", "Two years.", "Thirty days."), score = 1, similarity = c(0.9, 0.8, 0.7),
                 weight = 1, stringsAsFactors = FALSE)
    }
  )
  s <- dragonfarm:::tool_call("search_documents", list(set = "kb", query = "warranty", k = 1, source = "Policy.PDF"))
  expect_true(s$ok)
  expect_equal(seen, 3L)                                        # the whole set is ranked
  expect_length(s$result, 1)
  expect_equal(s$result[[1]]$id, "abc-001")                     # that document's best excerpt, renumbered
  expect_equal(s$result[[1]]$n, 1L)
  bad <- dragonfarm:::tool_call("search_documents", list(set = "kb", query = "warranty", source = "other.pdf"))
  expect_equal(bad$code, "INVALID_ARGUMENTS")
  expect_match(bad$error, "policy.pdf")
})

test_that("build_training_set saves the rows train_model would use, for a person to read", {
  runs <- tempfile("runs-"); dir.create(runs)
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  qfile <- file.path(runs, "kb-questions.jsonl"); writeLines("{}", qfile)
  seen <- NULL
  testthat::local_mocked_bindings(
    dragon_questions_load = function(path) structure(list(), class = "dragon_questions"),
    dragon_questions_dataset = function(qa, negatives = 0.15, ...) {
      seen <<- negatives
      d <- data.frame(question = c("How long?", "What colour?"), context = c("[1] Thirty days.", "[1] Two years."),
                      answer = c("Thirty days [1].", "The documents do not cover this."), negative = c(FALSE, TRUE))
      dragon_map(dragon_dataset(d), prompt = "Documentation excerpts:\n{context}\n\nQuestion: {question}", response = "answer")
    }
  )
  r <- dragonfarm:::tool_call("build_training_set", list(questions = qfile, negatives = 0.2), agent = "trainer")
  expect_true(r$ok)
  expect_equal(seen, 0.2)
  expect_equal(r$result[c("rows", "answered", "not_covered")], list(rows = 2L, answered = 1L, not_covered = 1L))
  expect_equal(basename(r$result$file), "kb-questions-training.jsonl")
  rows <- dragonfarm:::read_jsonl(r$result$file)
  expect_match(rows[[1]]$prompt, "Thirty days[.]\n\nQuestion: How long[?]")
  expect_true(rows[[2]]$negative)
  expect_equal(dragonfarm:::tool_call("build_training_set", list(questions = qfile), agent = "answer")$code, "NOT_ALLOWED")
})
