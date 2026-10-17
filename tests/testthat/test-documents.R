# Document sets: validation, loading, printing, and chunk access without Python
# (the fake set comes from helper-documents.R). Building a real set from files
# runs under DRAGONFARM_INTEGRATION=true.

test_that("dragon_documents validates its inputs before touching Python", {
  expect_error(dragon_documents(character()), "paths")
  expect_error(dragon_documents(c("a.md", NA)), "paths")
  expect_error(dragon_documents(file.path(tempdir(), "definitely-missing.pdf")), "not found")
  expect_error(dragon_documents(tempdir(), max_words = 5), "max_words")
  expect_error(dragon_documents(tempdir(), max_words = 100, min_words = 200), "min_words")
})

test_that("when every file is a scan, the error says so instead of listing formats", {
  src <- tempfile("scan-", fileext = ".pdf"); writeLines("x", src)
  scanned <- '{"n_sources": 0, "n_chunks": 0, "n_reused": 0, "failed": [{"name": "scan.pdf", "error": "ValueError: no text layer; this looks like a scanned PDF."}]}'
  testthat::local_mocked_bindings(run_python = function(module, args, ...) list(status = 0L, stdout = scanned, stderr = ""))
  expect_error(suppressWarnings(dragon_documents(src, runs_dir = tempfile("runs-"), index = FALSE)), "looks scanned")
  other <- '{"n_sources": 0, "n_chunks": 0, "n_reused": 0, "failed": [{"name": "a.bin", "error": "unsupported file type"}]}'
  testthat::local_mocked_bindings(run_python = function(module, args, ...) list(status = 0L, stdout = other, stderr = ""))
  expect_error(suppressWarnings(dragon_documents(src, runs_dir = tempfile("runs-"), index = FALSE)), "Supported")
})

test_that("a saved set loads, prints, lists, and exposes its chunks", {
  f <- write_fake_set()
  docs <- dragon_documents_load(f$dir)
  expect_s3_class(docs, "dragon_documents")
  expect_equal(docs$name, "kb")
  expect_equal(length(docs$manifest$sources), 3L)

  by_name <- dragon_documents_load("kb", runs_dir = f$root)
  expect_equal(by_name$dir, docs$dir)

  out <- cli::cli_fmt(print(docs))
  expect_true(any(grepl("policy.pdf: 2 chunks", out)))
  expect_true(any(grepl("changelog, down-weighted", out)))
  expect_true(any(grepl("failed: RuntimeError", out)))
  expect_true(any(grepl("index: none", out)))

  ch <- dragon_chunks(docs)
  expect_equal(nrow(ch), 3L)
  expect_equal(ch$section, c("Returns", "Warranty", "1.1.0"))
  expect_equal(ch$weight, c(1, 1, 0.7))
  expect_true(ch$quoted[2]); expect_false(ch$quoted[1])
  expect_equal(dragon_chunks(f$dir)$id, ch$id)

  lst <- dragon_documents_list(f$root)
  expect_equal(nrow(lst), 1L)
  expect_equal(lst$name, "kb"); expect_equal(lst$chunks, 3L); expect_false(lst$indexed)
  expect_equal(nrow(dragon_documents_list(tempfile())), 0L)
})

test_that("the example documents ship with the package", {
  d <- dragon_example_documents()
  files <- list.files(d, pattern = "[.]md$")
  expect_length(files, 3)
  txt <- readLines(file.path(d, "returns-and-warranty.md"), warn = FALSE)
  expect_true(any(grepl("^# ", txt)) && any(grepl("30 days", txt)))
})

test_that("loading something that is not a set fails clearly", {
  expect_error(dragon_documents_load(tempdir()), "not a document set")
  expect_error(dragon_chunks(42), "dragon_documents")
})

test_that("a document set is built from real files", {
  skip_if_not(identical(Sys.getenv("DRAGONFARM_INTEGRATION"), "true"), "set DRAGONFARM_INTEGRATION=true")
  skip_on_cran()
  src <- tempfile("src-"); dir.create(src)
  writeLines(c("# Returns", "", paste(rep("Any device can be returned within 30 days of delivery for a full refund.", 8), collapse = " "),
               "", "## Warranty", "", paste(rep("Every device carries a 2-year limited warranty from the delivery date.", 8), collapse = " ")),
             file.path(src, "policy.md"))
  writeLines(c("question,answer", "How long is the warranty?,Two years."), file.path(src, "faq.csv"))
  runs_dir <- tempfile("runs-")
  docs <- dragon_documents(src, name = "test set", runs_dir = runs_dir, index = FALSE)
  expect_equal(docs$name, "test-set")
  expect_null(docs$manifest$index)
  ch <- dragon_chunks(docs)
  expect_true(all(c("policy.md", "faq.csv") %in% ch$source))
  expect_true(any(grepl("30 days", ch$text)))
  again <- dragon_documents(src, name = "test set", runs_dir = runs_dir, index = FALSE)
  expect_equal(dragon_chunks(again)$id, ch$id)
})

test_that("files a folder holds that no reader handles are summed up in one line", {
  note <- dragonfarm:::skipped_note
  expect_null(note(list()))
  sk <- list(list(name = "a.png", ext = ".png", hint = NULL), list(name = "b.png", ext = ".png", hint = NULL),
             list(name = "old/c.doc", ext = ".doc", hint = "save it as .docx (Word: File > Save As) and add that"))
  expect_equal(note(sk), "Skipped 3 files dragonfarm can't read: 2 .png, 1 .doc (save it as .docx).")
  expect_equal(note(sk[3]), "Skipped 1 file dragonfarm can't read: 1 .doc (save it as .docx).")
})

test_that("every read records the set's version in the catalogue", {
  runs_dir <- tempfile("runs-")
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  f <- write_fake_set(root = runs_dir, name = "kb")
  src <- tempfile(fileext = ".md"); writeLines("x", src)
  ok <- '{"n_sources": 3, "n_chunks": 3, "n_reused": 0, "failed": [], "skipped": []}'
  testthat::local_mocked_bindings(run_python = function(module, args, ...) list(status = 0L, stdout = ok, stderr = ""))
  versions <- function() DBI::dbGetQuery(dragonfarm:::store_open(runs_dir), "SELECT version FROM set_versions WHERE set_name = 'kb'")$version
  suppressMessages(dragon_documents(src, name = "kb", runs_dir = runs_dir, index = FALSE))
  expect_equal(versions(), 1L)
  suppressMessages(dragon_documents(src, name = "kb", runs_dir = runs_dir, index = FALSE))
  expect_equal(versions(), 1L)                                  # unchanged chunks: same version
  cat('{"id": "kb-9", "source": "x.md", "text": "new"}\n', file = file.path(f$dir, "chunks.jsonl"), append = TRUE)
  suppressMessages(dragon_documents(src, name = "kb", runs_dir = runs_dir, index = FALSE))
  expect_equal(versions(), 1:2)                                 # changed chunks: a new version, the old one kept
})
