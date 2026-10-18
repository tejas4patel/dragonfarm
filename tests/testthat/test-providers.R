test_that("the provider catalogue lists OpenAI-style endpoints with their key and sign-up page", {
  cat <- dragonfarm:::provider_catalog()
  expect_true(all(c("openrouter", "groq") %in% names(cat)))
  for (p in cat) {
    expect_match(p$base_url, "^https://.*/v1$")
    expect_match(p$sign_up, "^https://")
    expect_match(p$key_env, "_API_KEY$")
  }
  expect_error(dragonfarm:::provider_info("nope"), class = "dragonfarm_error")
})

test_that("nothing goes to a provider until a person opts in", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  withr::local_envvar(OPENROUTER_API_KEY = "test-key")
  err <- tryCatch(dragonfarm:::provider_backend("openrouter", "some/model:free", runs_dir = runs), error = function(e) e)
  expect_equal(err$code, "NOT_OPTED_IN"); expect_match(conditionMessage(err), "OpenRouter")
  dragonfarm:::provider_opt_in("openrouter", runs_dir = runs)
  b <- dragonfarm:::provider_backend("openrouter", "some/model:free", runs_dir = runs)
  expect_equal(b$provider, "openrouter"); expect_equal(b$url, "https://openrouter.ai/api/v1")
  dragonfarm:::provider_opt_out("openrouter", runs_dir = runs)
  expect_false(dragonfarm:::provider_status("openrouter", runs)$opted_in)
})

test_that("a missing key says where to get one", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  withr::local_envvar(GROQ_API_KEY = "")
  dragonfarm:::provider_opt_in("groq", runs_dir = runs)
  expect_error(dragonfarm:::provider_backend("groq", "m", runs_dir = runs), "console.groq.com")
})

test_that("the daily cap stops requests, including in the middle of a chat", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  withr::local_envvar(OPENROUTER_API_KEY = "test-key")
  dragonfarm:::provider_opt_in("openrouter", daily_cap = 2, runs_dir = runs)
  b <- dragonfarm:::provider_backend("openrouter", "m", runs_dir = runs)
  for (i in 1:2) dragonfarm:::store_record_event("outbound", "openrouter.ai", ok = TRUE, runs_dir = runs)
  expect_equal(dragonfarm:::provider_status("openrouter", runs)$used_today, 2L)
  err <- tryCatch(dragonfarm:::chat_completion_request(b, list(list(role = "user", content = "hi")), 10, 0, 1),
                  error = function(e) e)
  expect_equal(err$code, "QUOTA_REACHED")
})

test_that("a chain falls back to the next backend and records it", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  registerS3method("backend_generate", "dragon_backend_fake", function(backend, target, conversations, ...) {
    if (isTRUE(backend$fail)) stop("429 Too Many Requests")
    list(paste("from", backend$kind))
  }, envir = asNamespace("dragonfarm"))
  fake <- function(kind, fail) structure(list(kind = kind, fail = fail, model = "m"), class = c("dragon_backend_fake", "dragon_backend"))
  ch <- dragonfarm:::backend_chain(fake("free", TRUE), fake("local", FALSE))
  expect_equal(dragonfarm:::backend_generate(ch, NULL, list(list()))[[1]], "from local")
  ev <- dragonfarm:::store_events(1, runs_dir = runs)
  expect_equal(ev$kind, "fallback"); expect_match(ev$detail, "429")
  expect_equal(dragonfarm:::backend_generate(dragonfarm:::backend_chain(fake("local", FALSE)), NULL, list(list()))[[1]], "from local")
  expect_error(dragonfarm:::backend_generate(dragonfarm:::backend_chain(fake("a", TRUE), fake("b", TRUE)), NULL, list(list())),
               "Every backend failed")
})
