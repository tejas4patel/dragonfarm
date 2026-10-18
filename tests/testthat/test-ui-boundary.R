# U1: the app reads and writes only through the stores' helpers; no Shiny
# module builds a path or touches a file itself.

test_that("no Shiny module touches the file system directly", {
  dir <- test_path("..", "..", "R")
  skip_if_not(dir.exists(dir), "package sources not available")
  calls <- c("file.path", "normalizePath", "list.files", "dir.create", "dir.exists", "file.exists", "unlink",
             "readLines", "writeLines", "file.copy", "file.remove", "file.rename", "read_json", "write_json", "readRDS", "saveRDS")
  hits <- character()
  for (f in list.files(dir, pattern = "^mod_.*[.]R$", full.names = TRUE)) {
    code <- readLines(f, warn = FALSE)
    code <- sub("#.*$", "", code)                                     # comments may mention them
    for (fn in calls) {
      at <- which(grepl(paste0("(^|[^A-Za-z0-9_.])", gsub(".", "[.]", fn, fixed = TRUE), "[(]"), code))
      if (length(at)) hits <- c(hits, sprintf("%s:%d %s()", basename(f), at, fn))
    }
  }
  expect_equal(hits, character())
})

test_that("the app's run helpers find, open and signal runs", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  mk <- function(id, state, adapter) {
    d <- file.path(runs, id); dir.create(d)
    jsonlite::write_json(list(model = list(id = "m")), file.path(d, "config.json"), auto_unbox = TRUE)
    jsonlite::write_json(list(state = state, remote = list(stage = "uploading")), file.path(d, "status.json"), auto_unbox = TRUE)
    if (adapter) { dir.create(file.path(d, "adapter")); writeLines("{}", file.path(d, "adapter", "adapter_config.json")) }
    d
  }
  mk("r-done", "succeeded", TRUE); mk("r-running", "running", TRUE); mk("r-bare", "succeeded", FALSE)
  expect_setequal(dragonfarm:::runs_with_adapter(runs)$id, c("r-done", "r-running"))
  expect_equal(dragonfarm:::runs_with_adapter(runs, succeeded_only = TRUE)$id, "r-done")
  expect_equal(dragonfarm:::run_find("r-done", runs)$id, "r-done")
  expect_null(dragonfarm:::run_find("nope", runs)); expect_null(dragonfarm:::run_find("", runs)); expect_null(dragonfarm:::run_find(NULL, runs))
  expect_error(dragonfarm:::run_open("nope", runs), class = "dragonfarm_error")
  r <- dragonfarm:::run_open("r-running", runs)
  before <- dragonfarm:::run_file_signature(r, "cancel.request")
  dragonfarm:::run_request_cancel(r)
  expect_true(file.exists(file.path(r$dir, "cancel.request")))
  expect_false(identical(before, dragonfarm:::run_file_signature(r, "cancel.request")))
  expect_equal(dragonfarm:::run_remote_state(r$dir)$stage, "uploading")
})

test_that("uploads are staged in the set's folder; pipeline records are listed newest first", {
  runs <- withr::local_tempdir()
  src <- withr::local_tempfile(fileext = ".md"); writeLines("# Hello", src)
  expect_null(dragonfarm:::documents_stage_uploads("kb", data.frame(name = character(), datapath = character()), runs))
  up <- dragonfarm:::documents_stage_uploads("kb", data.frame(name = "a.md", datapath = src), runs)
  expect_true(file.exists(file.path(up, "a.md")))
  dir.create(file.path(runs, "pipelines"))
  jsonlite::write_json(list(id = "older"), file.path(runs, "pipelines", "20261017-a.json"), auto_unbox = TRUE)
  jsonlite::write_json(list(id = "newer"), file.path(runs, "pipelines", "20261018-b.json"), auto_unbox = TRUE)
  expect_equal(vapply(dragonfarm:::pipeline_records(runs), `[[`, "", "id"), c("newer", "older"))
  expect_true(nzchar(dragonfarm:::pipeline_records_signature(runs)))
})

test_that("chat transcripts round-trip, and other files are refused", {
  f <- withr::local_tempfile(fileext = ".json")
  dragonfarm:::chat_transcript_write(list(list(role = "user", content = "hi")), f)
  expect_equal(dragonfarm:::chat_transcript_read(f)$messages[[1]]$content, "hi")
  g <- withr::local_tempfile(fileext = ".json"); writeLines('{"format": "something-else"}', g)
  expect_null(dragonfarm:::chat_transcript_read(g))
  expect_null(dragonfarm:::chat_transcript_read(withr::local_tempfile()))
})

test_that("R sources are ASCII (R CMD check warns otherwise)", {
  dir <- test_path("..", "..", "R")
  skip_if_not(dir.exists(dir), "package sources not available")
  bad <- character()
  for (f in list.files(dir, pattern = "[.]R$", full.names = TRUE)) {
    lines <- readLines(f, warn = FALSE, encoding = "UTF-8")
    at <- which(grepl("[^\x01-\x7F]", lines, perl = TRUE, useBytes = TRUE))
    if (length(at)) bad <- c(bad, sprintf("%s:%d", basename(f), at))
  }
  expect_equal(bad, character())
})
