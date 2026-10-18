test_that("the qualification checks pass on a fresh install and write a report with its fingerprint recorded", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  testthat::local_mocked_bindings(dragon_python = function(...) stop("no Python here"))
  f <- withr::local_tempfile(fileext = ".md")
  r <- dragonfarm:::qualification_report(f, runs_dir = runs)
  failing <- r$checks[r$checks$result == "FAIL", , drop = FALSE]
  expect_equal(paste(failing$check, failing$evidence, sep = ": "), character())   # names the check if one fails
  expect_equal(r$failed, 0)
  expect_gte(r$passed, 9)
  expect_true(all(r$checks$result %in% c("PASS", "INFO")))
  txt <- readLines(f)
  expect_true(any(grepl("evidence for a validation, not a validation", txt)))
  expect_true(any(grepl("The record refuses edits and deletions | PASS", txt, fixed = TRUE)))
  ev <- dragonfarm:::store_events(1, runs_dir = runs)
  expect_equal(ev$kind, "qualification"); expect_match(ev$detail, r$sha256)
})

test_that("a failing control shows as FAIL with its evidence", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  testthat::local_mocked_bindings(dragon_python = function(...) stop("no Python here"),
                                  pii_find = function(text) data.frame(type = character(), match = character(), context = character()))
  checks <- dragonfarm:::qualification_checks(runs)
  row <- checks[checks$check == "Personal-data patterns", ]
  expect_equal(row$result, "FAIL"); expect_match(row$evidence, "0 of 4 planted found")
})

test_that("Settings offers the report as a download", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  testthat::local_mocked_bindings(dragon_python = function(...) stop("no Python here"), keychain_available = function() FALSE)
  shiny::testServer(dragonfarm:::mod_settings_server, args = list(runs_dir = runs), {
    f <- output$qualify
    expect_true(file.exists(f))
    expect_true(any(grepl("dragonfarm qualification report", readLines(f))))
  })
})
