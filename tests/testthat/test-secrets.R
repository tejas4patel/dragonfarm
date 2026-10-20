# An in-memory keychain, so tests never touch the real one.
fake_keychain <- function(env = parent.frame()) {
  store <- new.env()
  testthat::local_mocked_bindings(
    keychain_available = function() TRUE,
    keychain_get = function(var) store[[var]],
    keychain_set = function(var, value) assign(var, value, envir = store),
    keychain_delete = function(var) if (exists(var, envir = store, inherits = FALSE)) rm(list = var, envir = store),
    .env = env
  )
  store
}

clean_env <- function(env = parent.frame()) {
  vars <- unlist(lapply(dragonfarm:::secret_catalog(), `[[`, "vars"))
  withr::local_envvar(stats::setNames(rep("", length(vars)), vars), .local_envir = env)
  withr::local_options(dragonfarm.runs_dir = withr::local_tempdir(.local_envir = env), .local_envir = env)
}

test_that("saving a key puts it in the keychain and the session, and records only its name", {
  clean_env(); store <- fake_keychain()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  expect_false(dragonfarm:::secret_status("huggingface")$set)
  dragonfarm:::secret_save("huggingface", list(HF_TOKEN = "  hf_abcdefgh1234 "))
  expect_equal(store$HF_TOKEN, "hf_abcdefgh1234"); expect_equal(Sys.getenv("HF_TOKEN"), "hf_abcdefgh1234")
  st <- dragonfarm:::secret_status("huggingface")
  expect_true(st$set); expect_equal(st$where, "keychain"); expect_match(st$masked, "1234$")
  ev <- dragonfarm:::store_events(1)
  expect_equal(ev$kind, "secret_saved"); expect_false(grepl("hf_abcdefgh1234", ev$detail))
  dragonfarm:::secret_remove("huggingface")
  expect_null(store$HF_TOKEN); expect_equal(Sys.getenv("HF_TOKEN"), "")
})

test_that("a service with two keys needs both", {
  clean_env(); fake_keychain()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  expect_error(dragonfarm:::secret_save("lightning", list(LIGHTNING_USER_ID = "u1", LIGHTNING_API_KEY = "")), "LIGHTNING_API_KEY")
  dragonfarm:::secret_save("lightning", list(LIGHTNING_USER_ID = "u1", LIGHTNING_API_KEY = "k1"))
  expect_true(dragonfarm:::lightning_ready())
})

test_that("saved keys load into a new session, without overriding an admin's", {
  clean_env(); store <- fake_keychain()
  assign("GROQ_API_KEY", "gsk_saved", envir = store)
  assign("HF_TOKEN", "hf_saved", envir = store)
  Sys.setenv(HF_TOKEN = "hf_admin")
  loaded <- dragonfarm:::secrets_load()
  expect_equal(loaded, "GROQ_API_KEY")
  expect_equal(Sys.getenv("GROQ_API_KEY"), "gsk_saved"); expect_equal(Sys.getenv("HF_TOKEN"), "hf_admin")
  expect_equal(dragonfarm:::secret_status("huggingface")$where, "environment")
})

test_that("without a usable keychain nothing is saved and it says why", {
  clean_env()
  testthat::local_mocked_bindings(keychain_problem = function() "The keyring package is not installed.")
  expect_error(dragonfarm:::secret_save("anthropic", list(ANTHROPIC_API_KEY = "sk-test")), "not installed")
  expect_equal(Sys.getenv("ANTHROPIC_API_KEY"), "")
})

test_that("the keychain message names the cause and the fix", {
  expect_match(dragonfarm:::keychain_problem(installed = FALSE), 'install.packages("keyring")', fixed = TRUE)
  skip_if_not_installed("keyring")
  testthat::local_mocked_bindings(default_backend = function() stop("no credential store"), .package = "keyring")
  expect_match(dragonfarm:::keychain_problem(), "no credential store")
  expect_false(dragonfarm:::keychain_available())
})

test_that("a kaggle.json downloaded from Kaggle is found", {
  d <- withr::local_tempdir()
  expect_null(dragonfarm:::kaggle_json_download(d))
  jsonlite::write_json(list(username = "ana", key = "abc123"), file.path(d, "kaggle (1).json"), auto_unbox = TRUE)
  k <- dragonfarm:::kaggle_json_download(d)
  expect_equal(k$username, "ana"); expect_equal(k$key, "abc123")
  writeLines("not json", file.path(d, "kaggle.json")); Sys.setFileTime(file.path(d, "kaggle.json"), Sys.time() + 60)
  expect_null(dragonfarm:::kaggle_json_download(d))
})

test_that("key checks read the service's answer and go through the gateway", {
  clean_env()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  Sys.setenv(HF_TOKEN = "hf_x", OPENROUTER_API_KEY = "or_x")
  seen <- character()
  testthat::local_mocked_bindings(http_ok = function(url, headers) { seen <<- c(seen, url); list(ok = grepl("huggingface", url), status = if (grepl("huggingface", url)) 200L else 401L) })
  expect_true(dragonfarm:::secret_check("huggingface")$ok)
  r <- dragonfarm:::secret_check("openrouter"); expect_false(r$ok); expect_match(r$message, "did not accept")
  expect_true(is.na(dragonfarm:::secret_check("lightning")$ok))
  expect_equal(seen, c("https://huggingface.co/api/whoami-v2", "https://openrouter.ai/api/v1/key"))
})

test_that("the Settings page saves, checks, removes, and opts in to a free tier", {
  clean_env(); store <- fake_keychain()
  runs <- getOption("dragonfarm.runs_dir")
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  testthat::local_mocked_bindings(secret_check = function(service) list(ok = TRUE, message = "Connected."))
  shiny::testServer(dragonfarm:::mod_settings_server, args = list(runs_dir = runs), {
    expect_match(output$pill_anthropic$html, "not set")
    session$setInputs(val_ANTHROPIC_API_KEY = "sk-ant-test9876")
    session$setInputs(save_anthropic = 1)
    expect_equal(store$ANTHROPIC_API_KEY, "sk-ant-test9876")
    expect_match(output$pill_anthropic$html, "saved.*9876")
    expect_match(output$msg_anthropic$html, "Connected")
    session$setInputs(remove_anthropic = 1)
    expect_match(output$pill_anthropic$html, "not set")
    session$setInputs(cap_groq = 20, agree_groq = FALSE, optin_groq = 1)
    expect_false(dragonfarm:::provider_status("groq", runs)$opted_in)          # not without agreeing
    session$setInputs(agree_groq = TRUE, optin_groq = 2)
    st <- dragonfarm:::provider_status("groq", runs)
    expect_true(st$opted_in); expect_equal(st$daily_cap, 20)
  })
})

test_that("Save and check with empty boxes re-checks a saved key, and asks for one when none is saved", {
  clean_env(); store <- fake_keychain()
  runs <- getOption("dragonfarm.runs_dir")
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  checked <- 0
  testthat::local_mocked_bindings(secret_check = function(service) { checked <<- checked + 1; list(ok = TRUE, message = "Connected.") })
  shiny::testServer(dragonfarm:::mod_settings_server, args = list(runs_dir = runs), {
    session$setInputs(val_GROQ_API_KEY = "", save_groq = 1)
    expect_match(output$msg_groq$html, "Fill in")
    expect_equal(checked, 0)
    session$setInputs(val_GROQ_API_KEY = "gsk_test1234", save_groq = 2)
    expect_equal(checked, 1)
    session$setInputs(val_GROQ_API_KEY = "", save_groq = 3)
    expect_equal(checked, 2)
    expect_equal(store$GROQ_API_KEY, "gsk_test1234")
    expect_match(output$msg_groq$html, "Connected")
  })
})
