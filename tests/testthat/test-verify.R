# A saved set whose sources are real files, and a mocked re-read that writes
# the given chunks and source hashes.
verify_fixture <- function() {
  root <- withr::local_tempdir(.local_envir = parent.frame())
  src <- file.path(root, "src"); dir.create(src)
  writeLines("Thirty days.", file.path(src, "policy.md"))
  dir <- file.path(root, "documents", "kb"); dir.create(dir, recursive = TRUE)
  man <- list(name = "kb", chunking = list(max_words = 170L, min_words = 35L, reader = 19L),
              sources = list(list(locator = file.path(src, "policy.md"), kind = "file", sha256 = "aaa", error = NULL),
                             list(locator = "https://example.com/faq", kind = "url", sha256 = "bbb", error = NULL)))
  dragonfarm:::write_json(man, file.path(dir, "manifest.json"))
  chunks <- list(list(id = "aaa-000", source_id = "aaa", text = "Thirty days."),
                 list(id = "bbb-000", source_id = "bbb", text = "Web page."))
  dragonfarm:::write_jsonl(chunks, file.path(dir, "chunks.jsonl"))
  list(root = root, dir = dir, src = src)
}

mock_reread <- function(text = "Thirty days.", sha = "aaa", reader = 19L) {
  function(paths, name, runs_dir, ...) {
    d <- file.path(runs_dir, "documents", name); dir.create(d, recursive = TRUE)
    dragonfarm:::write_json(list(name = name, chunking = list(reader = reader),
                                 sources = lapply(paths, function(p) list(locator = p, kind = "file", sha256 = sha))),
                            file.path(d, "manifest.json"))
    dragonfarm:::write_jsonl(list(list(id = paste0(sha, "-000"), source_id = sha, text = text)), file.path(d, "chunks.jsonl"))
    structure(list(dir = d, name = name), class = "dragon_documents")
  }
}

test_that("an unchanged set re-reads identically; web pages are listed, not fetched", {
  f <- verify_fixture()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  docs <- dragon_documents_load(f$dir)
  fetched <- NULL
  inner <- mock_reread()
  testthat::local_mocked_bindings(dragon_documents = function(paths, ...) { fetched <<- paths; inner(paths, ...) })
  v <- dragonfarm:::documents_verify(docs, runs_dir = f$root)
  expect_equal(v$verdict, "identical")
  expect_equal(v$not_checked, "https://example.com/faq")
  expect_false(any(grepl("^https?://", fetched)))
  expect_equal(dragonfarm:::store_events(1, runs_dir = f$root)$kind, "verify")
})

test_that("changed and missing files are named", {
  f <- verify_fixture()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  docs <- dragon_documents_load(f$dir)
  testthat::local_mocked_bindings(dragon_documents = mock_reread(text = "Sixty days.", sha = "ccc"))
  v <- dragonfarm:::documents_verify(docs, runs_dir = f$root)
  expect_equal(v$verdict, "sources changed"); expect_length(v$changed, 1)
  unlink(file.path(f$src, "policy.md"))
  v <- dragonfarm:::documents_verify(docs, runs_dir = f$root)
  expect_equal(v$verdict, "nothing to check"); expect_length(v$missing, 1)
})

test_that("a difference nothing explains is reported as such", {
  f <- verify_fixture()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  docs <- dragon_documents_load(f$dir)
  testthat::local_mocked_bindings(dragon_documents = mock_reread(text = "Thirty  days."))
  v <- dragonfarm:::documents_verify(docs, runs_dir = f$root)
  expect_equal(v$verdict, "differs"); expect_equal(v$chunks_differ, 2L)
  testthat::local_mocked_bindings(dragon_documents = mock_reread(text = "Thirty  days.", reader = 20L))
  expect_equal(dragonfarm:::documents_verify(docs, runs_dir = f$root)$verdict, "reader changed")
})
