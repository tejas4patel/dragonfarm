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
