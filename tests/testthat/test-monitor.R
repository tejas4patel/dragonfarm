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
