# D-11: training waits for a person when its rows hold likely personal data.

pii_ds <- function() {
  d <- data.frame(subject = c("Refund", "Reset"), body = c("Mail me at jane.doe@example.org please", "How do I reset it?"),
                  reply = c("Done.", "Hold the button."))
  dragon_map(dragon_dataset(d), prompt = "{subject}\n\n{body}", response = "reply")
}

test_that("personal data is found in training rows, conversations included", {
  h <- dragonfarm:::dataset_pii(pii_ds())
  expect_equal(h$row, 1L); expect_equal(h$type, "email")
  expect_equal(dragonfarm:::pii_counts(h), "1 email")
  conv <- dragon_conversations(list(list(list(role = "user", content = "Call (617) 555-0142"), list(role = "assistant", content = "OK"))))
  expect_equal(dragonfarm:::dataset_pii(conv)$type, "phone")
  expect_equal(nrow(dragonfarm:::dataset_pii(dragon_dataset(dragon_example_data()))), 0)   # the example tickets are clean
})

test_that("dragon_train warns about personal data before training", {
  testthat::local_mocked_bindings(prepare_run = function(...) stop("stop here"))
  expect_warning(expect_error(dragon_train(pii_ds(), "m"), "stop here"), "personal data: 1 email")
})

test_that("the train_model tool refuses rows with personal data until a person allows it", {
  runs <- tempfile("runs-"); dir.create(runs)
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  qf <- file.path(runs, "q.jsonl"); writeLines("{}", qf)
  launched <- FALSE
  testthat::local_mocked_bindings(
    dragon_questions_load = function(path) structure(list(), class = "dragon_questions"),
    dragon_questions_dataset = function(qa, ...) pii_ds(),
    hardware_info = function() NULL,
    dragon_train = function(...) { launched <<- TRUE; structure(list(id = "r1", dir = runs), class = "dragon_run") },
    dragon_status = function(run) list(state = "queued")
  )
  r <- dragonfarm:::tool_call("train_model", list(questions = qf, model = "Qwen/Qwen2.5-0.5B-Instruct"))
  expect_equal(r$code, "PERSONAL_DATA"); expect_match(r$error, "1 email"); expect_false(launched)
  r2 <- dragonfarm:::tool_call("train_model", list(questions = qf, model = "Qwen/Qwen2.5-0.5B-Instruct", allow_personal_data = TRUE))
  expect_true(r2$ok); expect_true(launched)
})

test_that("the Train step shows the hits and trains only after 'Train anyway'", {
  runs <- tempfile("runs-"); dir.create(runs)
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  ds <- pii_ds()
  state <- shiny::reactiveValues(dataset = ds, mapped = ds, model = list(id = "Qwen/Qwen2.5-0.5B-Instruct"), run = NULL, hardware = NULL)
  shiny::testServer(dragonfarm:::mod_train_server, args = list(state = state, nav_to = function(p) NULL, runs_dir = runs), {
    session$setInputs(start = 1)
    expect_equal(nrow(pii_hits()), 1)                       # the hits are held for the dialog
    expect_null(state$run)                                  # and nothing has started
    session$setInputs(pii_ok = 1)                           # "Train anyway": the decision is recorded
  })
  ev <- dragonfarm:::store_events(10, kind = "approval_decision", runs_dir = runs)
  expect_equal(ev$name, "train_with_personal_data")
  expect_match(ev$detail, "email")
})

test_that("public contacts an admin allows are not treated as personal data", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  d <- data.frame(p = c("Write to druginfo@fda.hhs.gov", "Mail jane.doe@example.org", "Call 301-796-3400"), r = "ok")
  ds <- dragon_map(dragon_dataset(d), prompt = "p", response = "r")
  expect_equal(nrow(dragonfarm:::dataset_pii(ds)), 3)
  pol <- dragonfarm:::policy_current(runs); pol$version <- NULL
  pol$pii_allow <- list("*@fda.hhs.gov", "301-796-3400")
  dragonfarm:::policy_set(pol, set_by = "admin", note = "FDA public contacts", runs_dir = runs)
  h <- dragonfarm:::dataset_pii(ds)
  expect_equal(h$match, "jane.doe@example.org")                        # only the person is left
  expect_false(dragonfarm:::pii_allowed("x@fdaXhhs.gov", "*@fda.hhs.gov"))   # dots are literal
  pol$pii_allow <- list(7)
  expect_match(dragonfarm:::policy_problems(pol), "pii_allow")
})
