fake_gpu <- list(device = "cuda", device_name = "NVIDIA GeForce RTX 4060 Laptop GPU", vram_gb = 8,
                 tier = list(model = "Qwen/Qwen2.5-7B-Instruct", load_in_4bit = TRUE))

test_that("where_report sums up this computer, keys, free tiers, Kaggle and the policy", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  cfg <- withr::local_tempdir()
  withr::local_envvar(GROQ_API_KEY = "gsk_test", OPENROUTER_API_KEY = "", KAGGLE_USERNAME = "", KAGGLE_KEY = "",
                      KAGGLE_API_TOKEN = "", KAGGLE_CONFIG_DIR = cfg, HF_TOKEN = "", ANTHROPIC_API_KEY = "")
  testthat::local_mocked_bindings(keychain_available = function() FALSE)
  w <- dragonfarm:::where_report(runs, hardware = fake_gpu)
  expect_s3_class(w, "dragon_where")
  expect_equal(w$local$model, "Qwen/Qwen2.5-7B-Instruct")
  expect_equal(w$train_where, "this computer")
  expect_true(w$services$groq$set); expect_false(w$services$openrouter$set)
  expect_length(w$usable_free, 0)                              # a key alone is not an opt-in
  dragonfarm:::provider_opt_in("groq", daily_cap = 2, runs_dir = runs)
  expect_equal(dragonfarm:::where_report(runs, hardware = fake_gpu)$usable_free, "groq")
  for (i in 1:2) dragonfarm:::outbound_check("https://api.groq.com/openai/v1", "free tier: groq", runs_dir = runs)
  expect_length(dragonfarm:::where_report(runs, hardware = fake_gpu)$usable_free, 0)   # cap reached
  out <- cli::cli_fmt(print(dragonfarm:::where_report(runs, hardware = fake_gpu)))
  expect_true(any(grepl("2 of 2 requests today", out)))
  expect_true(any(grepl("Any host", out)))
})

test_that("without a GPU, training goes to Kaggle only when it is ready and allowed", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  withr::local_envvar(KAGGLE_USERNAME = "ana", KAGGLE_KEY = "abc", KAGGLE_API_TOKEN = "")
  cpu <- list(device = "cpu", tier = list(model = "Qwen/Qwen2.5-1.5B-Instruct", load_in_4bit = FALSE))
  expect_match(dragonfarm:::where_report(runs, hardware = cpu)$train_where, "Kaggle")
  pol <- dragonfarm:::policy_current(runs); pol$outbound$allowed_hosts <- list()
  dragonfarm:::policy_set(pol, set_by = "test", runs_dir = runs)
  w <- dragonfarm:::where_report(runs, hardware = cpu)
  expect_match(w$train_where, "CPU")
  expect_true(any(grepl("Nothing: no outside hosts", cli::cli_fmt(print(w)))))
})

test_that("an unchecked machine says so instead of guessing", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  w <- dragonfarm:::where_report(runs, hardware = NULL)
  expect_match(w$local$label, "dragon_check")
})

test_that("Settings shows where things run, and it follows a new opt-in", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  withr::local_envvar(GROQ_API_KEY = "gsk_test", OPENROUTER_API_KEY = "")
  testthat::local_mocked_bindings(keychain_available = function() FALSE)
  shiny::testServer(dragonfarm:::mod_settings_server, args = list(runs_dir = runs), {
    html <- output$where$html
    expect_match(html, "Where|This computer")
    expect_match(html, "Groq: key saved, not opted in")
    session$setInputs(cap_groq = 5, agree_groq = TRUE, optin_groq = 1)
    expect_match(output$where$html, "Groq: in use when needed (0 of 5 requests today)", fixed = TRUE)
  })
})
