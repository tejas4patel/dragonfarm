# The catalog: sets and their versions, runs, and the append-only event log.

test_that("the catalog is created with its schema and events cannot be edited", {
  runs <- tempfile("runs-")
  con <- dragonfarm:::store_open(runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  expect_true(file.exists(file.path(runs, "dragonfarm.sqlite")))
  expect_setequal(intersect(DBI::dbListTables(con), c("meta", "document_sets", "set_versions", "runs", "events")),
                  c("meta", "document_sets", "set_versions", "runs", "events"))
  expect_equal(DBI::dbGetQuery(con, "SELECT value FROM meta WHERE key = 'schema_version'")$value, as.character(dragonfarm:::store_schema_version))
  expect_identical(dragonfarm:::store_open(runs), con)            # one connection per folder

  id <- dragonfarm:::store_record_event("tool", "search_documents", ok = TRUE, detail = list(args = list(query = "q")),
                                        duration_ms = 12, runs_dir = runs)
  expect_equal(id, 1L)                                             # the new event's id
  ev <- dragonfarm:::store_events(runs_dir = runs)
  expect_equal(nrow(ev), 1L)
  expect_equal(ev$name, "search_documents")
  expect_equal(jsonlite::fromJSON(ev$detail)$args$query, "q")
  expect_error(DBI::dbExecute(con, "UPDATE events SET ok = 0"), "append-only")
  expect_error(DBI::dbExecute(con, "DELETE FROM events"), "append-only")
})

test_that("syncing adds a set version only when its chunks change, and keeps the old ones", {
  f <- write_fake_set()
  runs <- dirname(dirname(f$dir))
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  first <- dragonfarm:::store_sync(runs)
  expect_equal(first$new_versions, 1L)
  expect_equal(dragonfarm:::store_sync(runs)$new_versions, 0L)    # nothing changed
  cat('{"id": "kb-999", "source": "x.md", "text": "new"}\n', file = file.path(f$dir, "chunks.jsonl"), append = TRUE)
  expect_equal(dragonfarm:::store_sync(runs)$new_versions, 1L)
  v <- DBI::dbGetQuery(dragonfarm:::store_open(runs), "SELECT version, chunks_md5 FROM set_versions WHERE set_name = 'kb' ORDER BY version")
  expect_equal(v$version, 1:2)
  expect_false(v$chunks_md5[1] == v$chunks_md5[2])
})

test_that("every tool call is recorded, failed ones included", {
  runs <- tempfile("runs-")
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::tool_call("search_documents", list(set = "missing", query = "q"))
  dragonfarm:::tool_call("search_documents", list(set = "x"))
  ev <- dragonfarm:::store_events(runs_dir = runs)
  expect_equal(nrow(ev), 2L)
  expect_equal(rev(ev$code), c("NOT_A_SET", "INVALID_ARGUMENTS"))
  expect_true(all(ev$ok == 0))
})

test_that("the record exports as CSV for an auditor, and the export is recorded with a checksum", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::store_record_event("tool", "search_documents", ok = TRUE, detail = list(args = list(query = "q")), runs_dir = runs)
  dragonfarm:::store_record_event("approval_request", "train_model", ok = FALSE, code = "NEEDS_APPROVAL", runs_dir = runs)
  f <- withr::local_tempfile(fileext = ".csv")
  out <- dragonfarm:::store_export(f, runs_dir = runs)
  expect_equal(out$rows, 2L)
  csv <- utils::read.csv(f)
  expect_equal(csv$kind, c("tool", "approval_request")); expect_equal(csv$code[2], "NEEDS_APPROVAL")
  expect_equal(out$sha256, dragonfarm:::file_digest(f)$sha256)
  ev <- dragonfarm:::store_events(1, runs_dir = runs)
  expect_equal(ev$kind, "record_export"); expect_match(ev$detail, out$sha256)
  later <- dragonfarm:::store_export(f, since = "2999-01-01", runs_dir = runs)
  expect_equal(later$rows, 0L)
})

test_that("the 7-day summary counts kinds, problems, outbound hosts and waiting approvals", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  rec <- function(...) dragonfarm:::store_record_event(..., runs_dir = runs)
  rec("tool", "search_documents", ok = TRUE); rec("tool", "list_runs", ok = FALSE, code = "NOT_ALLOWED")
  rec("outbound", "api.anthropic.com", ok = TRUE, detail = list(purpose = "judge", bytes = 2048))
  rec("outbound", "api.anthropic.com", ok = TRUE, detail = list(purpose = "judge", bytes = 1024))
  rec("approval_request", "train_model", ok = FALSE, code = "NEEDS_APPROVAL", detail = list(agent = "trainer", args = list()))
  sm <- dragonfarm:::store_summary(7, runs_dir = runs)
  expect_equal(as.integer(sm$kinds[["outbound"]]), 2L); expect_equal(as.integer(sm$kinds[["tool"]]), 2L)
  expect_equal(as.integer(sm$problems[["NOT_ALLOWED"]]), 1L)
  expect_equal(sm$outbound$calls, 2L); expect_equal(sm$outbound$bytes, 3072)
  expect_equal(sm$waiting, 1L)
})


test_that("a fingerprint is named after the algorithm that made it", {
  f <- withr::local_tempfile(lines = "abc")
  testthat::local_mocked_bindings(requireNamespace = function(...) FALSE, .package = "base")
  d <- dragonfarm:::file_digest(f)
  expect_named(d, "md5")
  expect_equal(d$md5, unname(tools::md5sum(f)))
})
