test_that("column names and templates both map", {
  ds <- dragon_dataset(toy_df())
  m1 <- dragon_map(ds, prompt = "subject", response = "reply")
  expect_equal(m1$mapping$prompt, "{`subject`}")
  m2 <- dragon_map(ds, prompt = "{subject}\n\n{body}", response = "reply", system = "You help.")
  expect_equal(m2$mapping$system, "You help.")
  msgs <- dragonfarm:::dataset_messages(m2, 1)
  expect_length(msgs, 1)
  roles <- vapply(msgs[[1]]$messages, `[[`, character(1), "role")
  expect_equal(roles, c("system", "user", "assistant"))
  expect_equal(msgs[[1]]$messages[[2]]$content, "Subject 1\n\nBody text 1")
  expect_equal(msgs[[1]]$messages[[3]]$content, "Reply 1")
})

test_that("missing columns are reported", {
  ds <- dragon_dataset(toy_df())
  expect_error(dragon_map(ds, prompt = "nope", response = "reply"), "not found")
  expect_error(dragon_map(ds, prompt = "{subject} {nope}", response = "reply"), "nope")
  expect_error(dragon_map(ds, prompt = "", response = "reply"), "non-empty")
})

test_that("column names with spaces work through backticks", {
  df <- data.frame(`my prompt` = c("a", "b"), out = c("x", "y"), check.names = FALSE)
  ds <- dragon_map(dragon_dataset(df), prompt = "my prompt", response = "out")
  msgs <- dragonfarm:::dataset_messages(ds)
  expect_equal(msgs[[2]]$messages[[1]]$content, "b")
  ds2 <- dragon_map(dragon_dataset(df), prompt = "Q: {my prompt}", response = "out")
  expect_equal(dragonfarm:::dataset_messages(ds2)[[1]]$messages[[1]]$content, "Q: a")
})

test_that("NA values render as empty strings", {
  df <- data.frame(p = c("a", NA), r = c("x", "y"), stringsAsFactors = FALSE)
  ds <- dragon_map(dragon_dataset(df), prompt = "p", response = "r")
  expect_equal(dragonfarm:::dataset_messages(ds)[[2]]$messages[[1]]$content, "")
})

test_that("split is deterministic and respects small datasets", {
  ds <- dragon_dataset(toy_df(100))
  s1 <- dragon_split(ds, eval_frac = 0.1, seed = 1)
  s2 <- dragon_split(ds, eval_frac = 0.1, seed = 1)
  expect_equal(s1$split$eval_idx, s2$split$eval_idx)
  expect_length(s1$split$eval_idx, 10)
  tiny <- dragon_split(dragon_dataset(toy_df(10)))
  expect_length(tiny$split$eval_idx, 0)
})

test_that("training files are written in chat format", {
  ds <- dragon_map(dragon_dataset(toy_df(40)), prompt = "{subject}\n{body}", response = "reply")
  dir <- tempfile("run-")
  files <- dragonfarm:::write_dataset_files(ds, dir)
  expect_equal(files$n_train + files$n_eval, 40)
  expect_equal(files$n_eval, 2)
  train <- dragonfarm:::read_jsonl(file.path(dir, "data", "train.jsonl"))
  expect_length(train, files$n_train)
  expect_named(train[[1]], "messages")
  expect_equal(train[[1]]$messages[[2]]$role, "assistant")
  expect_true(file.exists(file.path(dir, "data", "eval.jsonl")))
})

test_that("preview prints rows", {
  ds <- dragon_map(dragon_dataset(toy_df()), prompt = "subject", response = "reply")
  expect_message(out <- dragon_preview(ds, n = 2), "Row 1")
  expect_length(out, 2)
})

test_that("training on nothing says so plainly", {
  # dragon_feedback() returns sft = NULL before anyone has given feedback.
  expect_error(dragonfarm:::check_dataset(NULL, mapped = TRUE), "nothing to train on")
})

test_that("a printed template shows each line break once, as \\n", {
  ds <- dragon_map(dragon_dataset(dragon_example_data()), prompt = "{subject}\n\n{body}", response = "reply")
  out <- cli::cli_fmt(print(ds))
  expect_true(any(grepl('Prompt: "{subject}\\n\\n{body}"', out, fixed = TRUE)))
  expect_false(any(grepl("\\\\", out, fixed = TRUE)))                 # never a doubled backslash
})
