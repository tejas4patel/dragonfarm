test_that("a recorded read-only tool call replays and is compared", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  sets <- data.frame(name = "policies", sources = 3, chunks = 11, indexed = TRUE)
  testthat::local_mocked_bindings(dragon_documents_list = function(...) sets)
  r <- tool_call("list_document_sets")
  expect_true(r$ok)
  ev <- dragonfarm:::store_events(1, runs_dir = runs)
  d <- jsonlite::fromJSON(ev$detail, simplifyVector = FALSE)
  expect_equal(d$result_hash, dragonfarm:::result_hash(r$result))
  expect_match(d$result_preview, "policies")

  again <- dragonfarm:::tool_replay(ev$id, runs_dir = runs)
  expect_true(again$ok); expect_true(again$matches); expect_length(again$changes, 0)

  sets$chunks <- 12
  changed <- dragonfarm:::tool_replay(ev$id, runs_dir = runs)
  expect_false(changed$matches)
  expect_match(changed$now, "12")
  expect_true("replay" %in% dragonfarm:::store_events(runs_dir = runs)$kind)
})

test_that("calls that change something are never replayed", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::store_record_event("tool", "train_model", ok = TRUE, detail = list(args = list(model = "m"), result_hash = "x"))
  id <- dragonfarm:::store_events(1, runs_dir = runs)$id
  r <- dragonfarm:::tool_replay(id, runs_dir = runs)
  expect_false(r$ok); expect_equal(r$code, "NOT_REPLAYABLE")
  dragonfarm:::store_record_event("tool", "list_runs", ok = FALSE, code = "UNKNOWN")
  expect_equal(dragonfarm:::tool_replay(dragonfarm:::store_events(1, runs_dir = runs)$id, runs_dir = runs)$code, "NOT_REPLAYABLE")
  expect_error(dragonfarm:::tool_replay(99999, runs_dir = runs), class = "dragonfarm_error")
})

test_that("a changed context is named: a re-read set or another model", {
  then <- list(set = list(name = "s", version = 1, chunks_md5 = "a"), model = list(id = "m", revision = "r1"))
  now <- list(set = list(name = "s", version = 2, chunks_md5 = "b"), model = list(id = "m", revision = "r2"))
  ch <- dragonfarm:::context_changes(then, now)
  expect_length(ch, 2)
  expect_match(ch[1], "read again"); expect_match(ch[2], "r1.*r2")
  expect_length(dragonfarm:::context_changes(then, then), 0)
})

test_that("a recorded agent task replays with the same goal, agent and model", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  reply <- "Two sets."
  seen <- character()
  testthat::local_mocked_bindings(backend_generate = function(backend, target, ...) { seen <<- c(seen, target$model); list(reply) })
  r <- dragonfarm:::agent_run("Which runs failed?", agent = "ops", model = "Qwen/Qwen2.5-7B-Instruct")
  id <- dragonfarm:::store_events(1, kind = "agent_run", runs_dir = runs)$id
  same <- dragonfarm:::agent_replay(id, runs_dir = runs)
  expect_true(same$matches)
  expect_equal(unique(seen), "Qwen/Qwen2.5-7B-Instruct")
  reply <- "Three sets."
  expect_false(dragonfarm:::agent_replay(id, runs_dir = runs)$matches)
})

test_that("every code the package raises is in the registry", {
  codes <- names(jsonlite::read_json(system.file("tools", "error_codes.json", package = "dragonfarm")))
  src <- testthat::test_path("..", "..", "R")
  skip_if(!dir.exists(src), "R sources not available (installed package)")
  lines <- unlist(lapply(list.files(src, pattern = "[.]R$", full.names = TRUE), readLines))
  used <- unique(sub('code = "([A-Z_]+)"', "\\1", unlist(regmatches(lines, gregexpr('code = "[A-Z_]+"', lines)))))
  expect_gt(length(used), 5)
  expect_equal(setdiff(used, codes), character())
})

test_that("a recorded answer replays: same excerpts, prompt and answer, or what changed", {
  f <- write_fake_set()
  runs <- dirname(dirname(f$dir))
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  reply <- "Thirty days [1]."
  ids <- c("abc-000", "abc-001")
  testthat::local_mocked_bindings(
    dragon_retrieve = function(docs, question, k = 4, ...) data.frame(n = 1:2, id = ids, source = "policy.pdf",
                                                                     section = "s", page = NA_integer_,
                                                                     text = c("Thirty days.", "Two years."), similarity = c(0.9, 0.5)),
    backend_generate = function(...) list(reply)
  )
  a <- dragon_ask(dragon_documents_load(f$dir), "How long is the return window?", model = "Qwen/Qwen2.5-7B-Instruct", k = 2)
  r <- dragonfarm:::ask_replay(a$trace, runs)
  expect_true(r$ok); expect_true(r$matches); expect_true(r$same_excerpts); expect_true(r$same_prompt)
  expect_equal(r$changes, character())

  reply <- "Thirty days."                                   # the model answers differently on the same context
  r <- dragonfarm:::ask_replay(a$trace, runs)
  expect_false(r$matches); expect_true(r$same_excerpts); expect_equal(r$changes, character())

  ids <- c("abc-001", "abc-000")                            # retrieval ranks differently
  r <- dragonfarm:::ask_replay(a$trace, runs)
  expect_match(r$changes, "different excerpts", all = FALSE)

  cat('{"id":"abc-002","source":"policy.pdf","section":"x","text":"New.","n_words":1}\n', file = file.path(f$dir, "chunks.jsonl"), append = TRUE)
  r <- dragonfarm:::ask_replay(a$trace, runs)
  expect_match(r$changes, "read again", all = FALSE)
  ev <- dragonfarm:::store_events(runs_dir = runs)
  expect_true(any(ev$kind == "replay" & ev$name == "ask"))
})

test_that("answers from a model server or other events are not replayed", {
  f <- write_fake_set()
  runs <- dirname(dirname(f$dir))
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  id <- dragonfarm:::store_record_event("ask", "kb", ok = TRUE, runs_dir = runs,
    detail = list(question = "Q?", set = "kb", model = "llama3", answer_hash = "x", settings = list(k = 4, server = TRUE)))
  expect_equal(dragonfarm:::ask_replay(id, runs)$code, "NOT_REPLAYABLE")
  old <- dragonfarm:::store_record_event("ask", "kb", ok = TRUE, runs_dir = runs,
    detail = list(question = "Q?", set = "kb", model = "llama3", answer_hash = "x", settings = list(k = 4)))
  expect_match(dragonfarm:::ask_replay(old, runs)$error, "model server")      # older record: judged by the model name
  other <- dragonfarm:::store_record_event("tool", "list_runs", ok = TRUE, runs_dir = runs)
  expect_equal(dragonfarm:::ask_replay(other, runs)$code, "NOT_REPLAYABLE")
})
