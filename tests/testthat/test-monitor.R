test_that("the Monitor module archives, deletes, and restores runs", {
  runs_dir <- tempfile("runs-")
  dir.create(runs_dir)
  dir <- file.path(runs_dir, "20260913-101500-smollm2")
  dir.create(dir)
  file.copy(list.files(fixture_path("run1"), full.names = TRUE), dir, recursive = TRUE)

  state <- shiny::reactiveValues(run = NULL)
  shiny::testServer(dragonfarm:::mod_monitor_server, args = list(state = state, runs_dir = runs_dir), {
    session$setInputs(run = "20260913-101500-smollm2")
    df <- runs()
    expect_equal(df$id, "20260913-101500-smollm2")

    # archive moves it out of the active list (runs() is a reactivePoll;
    # elapse() advances the mock clock past its interval so it re-checks)
    session$setInputs(archive = 1)
    session$elapse(3100)
    expect_equal(nrow(runs()), 0)
    expect_false(dir.exists(dir))
    expect_true(dir.exists(file.path(runs_dir, "archived", "20260913-101500-smollm2")))

    # switch to the archived view and restore it
    session$setInputs(show_archived = TRUE)
    session$elapse(3100)
    df2 <- runs()
    expect_equal(df2$id, "20260913-101500-smollm2")
    session$setInputs(run = "20260913-101500-smollm2", restore = 1)
    expect_true(dir.exists(dir))

    # delete asks for confirmation before removing anything
    session$setInputs(show_archived = FALSE, run = "20260913-101500-smollm2", delete = 1)
    expect_true(dir.exists(dir))   # not deleted yet; awaiting confirmation
    session$setInputs(delete_confirm = 1)
    session$elapse(3100)
    expect_false(dir.exists(dir))
    expect_equal(nrow(runs()), 0)
  })
})

test_that("the Monitor module forgets a currently launched run when it is archived or deleted", {
  runs_dir <- tempfile("runs-")
  dir.create(runs_dir)
  dir <- file.path(runs_dir, "20260913-101500-smollm2")
  dir.create(dir)
  file.copy(list.files(fixture_path("run1"), full.names = TRUE), dir, recursive = TRUE)
  run <- dragon_run(dir)

  state <- shiny::reactiveValues(run = run)
  shiny::testServer(dragonfarm:::mod_monitor_server, args = list(state = state, runs_dir = runs_dir), {
    session$setInputs(run = "20260913-101500-smollm2", archive = 1)
    expect_null(state$run)
  })
})

test_that("run buttons follow the run's state", {
  html <- function(s) paste(as.character(dragonfarm:::run_actions_ui(s)), collapse = "")
  expect_match(html("running"), "Cancel run")
  expect_no_match(html("running"), "Resume")
  expect_match(html("queued"), "Cancel run")
  expect_match(html("failed"), "Resume from checkpoint")
  expect_match(html("cancelled"), "Resume from checkpoint")
  expect_no_match(html("succeeded"), "Cancel|Resume")
  expect_no_match(html(NULL), "Cancel|Resume")
})

test_that("the Activity card lists events, filters them, and shows details", {
  runs_dir <- tempfile("runs-")
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::store_record_event("tool", "search_documents", ok = TRUE, detail = list(args = list(query = "warranty")),
                                  duration_ms = 40, runs_dir = runs_dir)
  dragonfarm:::store_record_event("tool", "read_documents", ok = FALSE, code = "NOT_ALLOWED", runs_dir = runs_dir)
  dragonfarm:::store_record_event("approval_request", "read_documents", ok = FALSE, code = "NEEDS_APPROVAL", runs_dir = runs_dir)
  state <- shiny::reactiveValues(run = NULL, dataset = NULL)
  shiny::testServer(dragonfarm:::mod_monitor_server, args = list(state = state, runs_dir = runs_dir), {
    session$setInputs(activity_filter = "all")
    html <- output$activity
    expect_match(html, "search_documents")
    expect_match(html, "NOT_ALLOWED")
    session$setInputs(activity_filter = "approval")
    expect_match(output$activity, "NEEDS_APPROVAL")
    expect_false(grepl("search_documents", output$activity))
    session$setInputs(activity_filter = "failed")
    expect_match(output$activity, "NOT_ALLOWED")
    expect_false(grepl("NEEDS_APPROVAL", output$activity))
    session$setInputs(activity_filter = "all", activity_pick = "1")
    expect_match(output$activity_detail, "warranty")
  })
})

test_that("the approvals card lists held calls and runs one when approved", {
  runs_dir <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs_dir)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  pol <- dragonfarm:::policy_default()
  pol$approvals$tools <- c(unlist(pol$approvals$tools), "list_runs")
  dragonfarm:::policy_set(pol, set_by = "admin", runs_dir = runs_dir)
  tool_call("list_runs", list(limit = 3), agent = "ops")
  tool_call("list_runs", list(limit = 9), agent = "ops")
  ids <- dragonfarm:::approvals_pending(runs_dir)$id
  state <- shiny::reactiveValues(run = NULL, dataset = NULL)
  shiny::testServer(dragonfarm:::mod_monitor_server, args = list(state = state, runs_dir = runs_dir), {
    html <- output$approvals
    expect_match(html, "list_runs"); expect_match(html, "limit = 3"); expect_match(html, "limit = 9")
    session$setInputs(approval_pick = as.character(ids[1]), approval_note = "ok")
    session$setInputs(approve = 1)
    expect_equal(dragonfarm:::approvals_pending(runs_dir)$id, ids[2])
    session$setInputs(approval_pick = as.character(ids[2]))
    session$setInputs(decline = 1)
    expect_equal(nrow(dragonfarm:::approvals_pending(runs_dir)), 0)
  })
  ev <- dragonfarm:::store_events(10, runs_dir = runs_dir)
  expect_equal(sum(ev$kind == "approval_decision"), 2)
  expect_equal(sum(ev$kind == "tool" & ev$ok == 1), 1)              # only the approved one ran
})

test_that("Monitor proposes a run as a model version, signs it off, and replays a recorded call", {
  runs_dir <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs_dir)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  d <- file.path(runs_dir, "20261018-run1"); dir.create(file.path(d, "data"), recursive = TRUE)
  jsonlite::write_json(list(stage = "sft", created_at = "2026-10-18T00:00:00Z", model = list(id = "Qwen/Qwen2.5-0.5B-Instruct"),
                            data = list(train = "data/train.jsonl")), file.path(d, "config.json"), auto_unbox = TRUE)
  jsonlite::write_json(list(state = "succeeded", eval_loss = 1.1), file.path(d, "status.json"), auto_unbox = TRUE)
  writeLines("{}", file.path(d, "data", "train.jsonl"))
  sets <- data.frame(name = "kb", sources = 1, chunks = 3, indexed = TRUE)
  testthat::local_mocked_bindings(dragon_documents_list = function(...) sets)
  tool_call("list_document_sets")
  call_id <- dragonfarm:::store_events(1, kind = "tool", runs_dir = runs_dir)$id
  state <- shiny::reactiveValues(run = NULL, dataset = NULL)
  shiny::testServer(dragonfarm:::mod_monitor_server, args = list(state = state, runs_dir = runs_dir), {
    session$setInputs(run = "20261018-run1", reg_name = "support-bot")
    session$setInputs(reg_propose = 1)
    expect_match(output$registry, "support-bot")
    expect_match(output$registry, "candidate")
    session$setInputs(reg_pick = "support-bot@1", reg_decision = "approved", reg_meaning = "Approved for support tickets")
    session$setInputs(reg_sign = 1)
    expect_match(output$registry, "approved")
    expect_equal(dragonfarm:::registry_approved("support-bot", runs_dir = runs_dir)$version, 1L)
    session$setInputs(activity_filter = "all", activity_pick = as.character(call_id))
    session$setInputs(replay = 1)
    expect_match(output$replay_ui$html, "Same result as before")
  })
})

test_that("a running run with no progress for too long is called stalled", {
  dir <- copy_fixture_run()
  run <- dragon_run(dir)
  st <- list(state = "running")
  now <- file.info(file.path(dir, "progress.jsonl"))$mtime
  expect_null(dragonfarm:::run_stalled(run, st, now = now + 10 * 60))              # 10 min: not yet
  expect_equal(dragonfarm:::run_stalled(run, st, now = now + 40 * 60), 40)         # 40 min with ~25 s gaps: stalled
  expect_null(dragonfarm:::run_stalled(run, list(state = "succeeded"), now = now + 600 * 60))
  unlink(file.path(dir, "progress.jsonl"))
  started <- file.info(file.path(dir, "status.json"))$mtime
  expect_null(dragonfarm:::run_stalled(run, st, now = started + 20 * 60))          # loading a model: grace of 30 min
  expect_equal(dragonfarm:::run_stalled(run, st, now = started + 45 * 60), 45)
})

test_that("Monitor says how much room runs take, the largest first", {
  dir <- copy_fixture_run()
  runs <- data.frame(id = c("a", "b"), dir = c(dir, tempdir()))
  writeLines(strrep("x", 5000), file.path(dir, "big.bin"))
  sp <- dragonfarm:::runs_space(data.frame(id = "a", dir = dir))
  expect_gt(sp$bytes, 5000)
  expect_match(dragonfarm:::fmt_bytes(1.5e9), "1.5 GB")
  expect_equal(nrow(dragonfarm:::runs_space(data.frame(id = character(), dir = character()))), 0)
  state <- shiny::reactiveValues(run = NULL, dataset = NULL)
  shiny::testServer(dragonfarm:::mod_monitor_server, args = list(state = state, runs_dir = dirname(dir)), {
    session$setInputs(show_archived = FALSE, run = basename(dir))
    expect_match(output$space$html, "1 run uses")
    expect_match(output$facts$html, "Size on disk")
  })
})
