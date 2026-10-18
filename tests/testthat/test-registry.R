fake_run <- function(runs, id, state = "succeeded", eval_loss = 1.2) {
  d <- file.path(runs, id)
  dir.create(file.path(d, "data"), recursive = TRUE)
  jsonlite::write_json(list(model = list(id = "Qwen/Qwen2.5-0.5B-Instruct", revision = "abc123"), data = list(train = "data/train.jsonl")),
                       file.path(d, "config.json"), auto_unbox = TRUE)
  st <- list(state = state); if (!is.null(eval_loss)) st$eval_loss <- eval_loss
  jsonlite::write_json(st, file.path(d, "status.json"), auto_unbox = TRUE)
  writeLines('{"prompt": "a", "response": "b"}', file.path(d, "data", "train.jsonl"))
  d
}

test_that("an evaluated run becomes a candidate, and only a stated sign-off approves it", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  r1 <- fake_run(runs, "run-1")
  p <- dragonfarm:::registry_propose(r1, "support-bot", runs_dir = runs)
  expect_equal(p$version, 1L); expect_equal(p$status, "candidate")
  l <- dragonfarm:::registry_list(runs_dir = runs)
  expect_equal(l$status, "candidate"); expect_equal(l$revision, "abc123")
  expect_null(dragonfarm:::registry_approved("support-bot", runs_dir = runs))

  expect_error(dragonfarm:::registry_sign_off("support-bot", 1, "approved", meaning = " ", runs_dir = runs), "means")
  dragonfarm:::registry_sign_off("support-bot", 1, "approved", meaning = "Approved for answering support tickets.",
                                 signer = "tejas", runs_dir = runs)
  a <- dragonfarm:::registry_approved("support-bot", runs_dir = runs)
  expect_equal(a$version, 1L); expect_equal(a$signer, "tejas"); expect_match(a$meaning, "support tickets")
  expect_error(dragonfarm:::registry_sign_off("support-bot", 1, "approved", meaning = "again", runs_dir = runs), "cannot be approved")

  p2 <- dragonfarm:::registry_propose(fake_run(runs, "run-2", eval_loss = 0.9), "support-bot", runs_dir = runs)
  expect_equal(p2$version, 2L)
  dragonfarm:::registry_sign_off("support-bot", 2, "approved", meaning = "Better held-out loss.", runs_dir = runs)
  dragonfarm:::registry_sign_off("support-bot", 1, "retired", meaning = "Replaced by version 2.", runs_dir = runs)
  expect_equal(dragonfarm:::registry_list("support-bot", runs_dir = runs)$status, c("retired", "approved"))
  expect_equal(dragonfarm:::registry_approved("support-bot", runs_dir = runs)$version, 2L)
})

test_that("unfinished or unevaluated runs are not proposed", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  expect_error(dragonfarm:::registry_propose(fake_run(runs, "r-fail", state = "failed"), "m", runs_dir = runs), "not succeeded")
  err <- tryCatch(dragonfarm:::registry_propose(fake_run(runs, "r-noeval", eval_loss = NULL), "m", runs_dir = runs), error = function(e) e)
  expect_equal(err$code, "NOT_EVALUATED")
  expect_error(dragonfarm:::registry_propose(fake_run(runs, "r-ok"), "bad name!", runs_dir = runs), "letters")
})

test_that("versions and sign-offs cannot be edited or deleted", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::registry_propose(fake_run(runs, "run-1"), "m", runs_dir = runs)
  dragonfarm:::registry_sign_off("m", 1, "rejected", meaning = "Too verbose.", runs_dir = runs)
  con <- dragonfarm:::store_open(runs)
  expect_error(DBI::dbExecute(con, "UPDATE model_versions SET run_id = 'x'"), "append-only")
  expect_error(DBI::dbExecute(con, "DELETE FROM model_signoffs"), "append-only")
  expect_error(dragonfarm:::registry_sign_off("m", 1, "approved", meaning = "changed my mind", runs_dir = runs), "rejected")
})

test_that("the policy can require a second person to sign", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  pol <- dragonfarm:::policy_default(); pol$registry$separate_signer <- TRUE
  dragonfarm:::policy_set(pol, set_by = "admin", runs_dir = runs)
  dragonfarm:::registry_propose(fake_run(runs, "run-1"), "m", proposed_by = "ana", runs_dir = runs)
  err <- tryCatch(dragonfarm:::registry_sign_off("m", 1, "approved", meaning = "ok", signer = "ana", runs_dir = runs), error = function(e) e)
  expect_equal(err$code, "NOT_ALLOWED")
  dragonfarm:::registry_sign_off("m", 1, "approved", meaning = "ok", signer = "ben", runs_dir = runs)
  expect_equal(dragonfarm:::registry_status("m", 1, runs_dir = runs), "approved")
})

test_that("an agent's promote_model waits for a person", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  fake_run(runs, "run-1")
  r <- tool_call("promote_model", list(run = "run-1", name = "m"), agent = "trainer")
  expect_equal(r$code, "NEEDS_APPROVAL")
  out <- dragonfarm:::approval_decide(dragonfarm:::approvals_pending(runs)$id, approve = TRUE, runs_dir = runs)
  expect_true(out$ok); expect_equal(out$result$status, "candidate")
})

test_that("a schema-1 catalogue gains the registry tables when opened", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  con <- DBI::dbConnect(RSQLite::SQLite(), file.path(runs, "dragonfarm.sqlite"))
  DBI::dbExecute(con, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
  DBI::dbExecute(con, "INSERT INTO meta VALUES ('schema_version', '1')")
  DBI::dbDisconnect(con)
  con <- dragonfarm:::store_open(runs)
  expect_equal(DBI::dbGetQuery(con, "SELECT value FROM meta WHERE key = 'schema_version'")$value, "2")
  expect_true(all(c("model_versions", "model_signoffs", "events") %in% DBI::dbListTables(con)))
})

test_that("in governed mode only an approved version's run answers people", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  r1 <- fake_run(runs, "run-1")
  target <- list(model = "Qwen/Qwen2.5-0.5B-Instruct", adapter = file.path(r1, "adapter"))
  expect_true(dragonfarm:::serving_check(target, runs))                     # governed mode is off by default
  pol <- dragonfarm:::policy_default(); pol$registry$governed <- TRUE
  dragonfarm:::policy_set(pol, set_by = "admin", note = "governed", runs_dir = runs)
  err <- tryCatch(dragonfarm:::serving_check(target, runs), dragonfarm_error = function(e) e)
  expect_equal(err$code, "NOT_APPROVED")
  expect_true(dragonfarm:::serving_check(list(model = "Qwen/Qwen2.5-7B-Instruct", adapter = NULL), runs))   # untrained: fine
  dragonfarm:::registry_propose(r1, "support-bot", runs_dir = runs)
  expect_error(dragonfarm:::serving_check(target, runs), class = "dragonfarm_error")                       # a candidate is not enough
  dragonfarm:::registry_sign_off("support-bot", 1, "approved", meaning = "For support tickets.", runs_dir = runs)
  expect_true(dragonfarm:::serving_check(target, runs))
  dir.create(file.path(r1, "merged"))
  merged <- list(model = file.path(r1, "merged"), adapter = NULL)                  # its merged copy, in the default place
  expect_true(dragonfarm:::serving_check(merged, runs))
  r2 <- fake_run(runs, "run-2"); dir.create(file.path(r2, "merged"))
  expect_error(dragonfarm:::serving_check(list(model = file.path(r2, "merged"), adapter = NULL), runs), class = "dragonfarm_error")
  dragonfarm:::registry_sign_off("support-bot", 1, "retired", meaning = "Replaced.", runs_dir = runs)
  expect_error(dragonfarm:::serving_check(target, runs), class = "dragonfarm_error")                       # retired: no longer
  pol$registry$governed <- "yes"
  expect_match(dragonfarm:::policy_problems(pol), "governed")
})

test_that("Ask refuses an unapproved run in governed mode, before anything runs", {
  f <- write_fake_set()
  runs <- dirname(dirname(f$dir))
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  pol <- dragonfarm:::policy_default(); pol$registry$governed <- TRUE
  dragonfarm:::policy_set(pol, set_by = "admin", runs_dir = runs)
  called <- FALSE
  testthat::local_mocked_bindings(
    dragon_retrieve = function(...) data.frame(n = 1, id = "abc-000", source = "policy.pdf", section = "s", page = NA, text = "Thirty days.", similarity = 1),
    resolve_target = function(x) list(model = "Qwen/Qwen2.5-0.5B-Instruct", adapter = file.path(runs, "run-x", "adapter")),
    backend_generate = function(...) { called <<- TRUE; list("Thirty days [1].") }
  )
  expect_error(dragon_ask(dragon_documents_load(f$dir), "How long?", model = "run-x"), class = "dragonfarm_error")
  expect_false(called)
  r <- dragonfarm:::tool_call("answer_question", list(set = f$dir, question = "How long?", model = "run-x"))
  expect_equal(r$code, "NOT_APPROVED")
})

test_that("run pickers say which runs are not approved, only in governed mode", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  r1 <- fake_run(runs, "run-1"); fake_run(runs, "run-2")
  expect_equal(dragonfarm:::approval_note(c("run-1", "run-2"), runs), c("", ""))      # off: no notes
  pol <- dragonfarm:::policy_default(); pol$registry$governed <- TRUE
  dragonfarm:::policy_set(pol, set_by = "admin", runs_dir = runs)
  dragonfarm:::registry_propose(r1, "bot", runs_dir = runs)
  dragonfarm:::registry_sign_off("bot", 1, "approved", meaning = "ok", runs_dir = runs)
  expect_equal(dragonfarm:::approval_note(c("run-1", "run-2"), runs), c("", " - not approved"))
})
