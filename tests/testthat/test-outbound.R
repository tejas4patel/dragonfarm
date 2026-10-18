no_outbound <- function(runs, hosts = list()) {
  pol <- dragonfarm:::policy_default()
  pol$outbound$allowed_hosts <- hosts
  dragonfarm:::policy_set(pol, set_by = "admin", runs_dir = runs)
}

test_that("hosts are read from URLs and this machine is not outbound", {
  h <- dragonfarm:::outbound_host
  expect_equal(h("https://api.anthropic.com/v1/messages"), "api.anthropic.com")
  expect_equal(h("http://user@Example.COM:8080/x?y=1"), "example.com")
  expect_equal(h("http://[::1]:11434/v1"), "[::1]")
  expect_true(dragonfarm:::is_local_host(h("http://localhost:11434/v1")))
  expect_true(dragonfarm:::is_local_host(h("http://127.0.0.1:8000")))
  expect_false(dragonfarm:::is_local_host(h("https://gpu-box.example.org/v1")))
})

test_that("allowed hosts can be exact, wildcard subdomains, or everything", {
  a <- dragonfarm:::host_allowed
  expect_true(a("api.anthropic.com", "api.anthropic.com"))
  expect_true(a("cdn.huggingface.co", "*.huggingface.co"))
  expect_true(a("huggingface.co", "*.huggingface.co"))
  expect_false(a("evilhuggingface.co", "*.huggingface.co"))
  expect_true(a("anything.org", "*"))
  expect_false(a("anything.org", character()))
})

test_that("every outbound call is recorded, and the policy can block it", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::outbound_check("https://api.anthropic.com", "Claude API: 2 prompts", bytes = 120, runs_dir = runs)
  ev <- dragonfarm:::store_events(1, runs_dir = runs)
  expect_equal(ev$kind, "outbound"); expect_equal(ev$name, "api.anthropic.com"); expect_match(ev$detail, "2 prompts")
  dragonfarm:::outbound_check("http://localhost:11434/v1", "a model server", runs_dir = runs)
  expect_equal(nrow(dragonfarm:::store_events(10, kind = "outbound", runs_dir = runs)), 1)   # local is not recorded

  no_outbound(runs, list("*.huggingface.co"))
  err <- tryCatch(dragonfarm:::outbound_check("https://api.anthropic.com", "Claude API", runs_dir = runs), error = function(e) e)
  expect_equal(err$code, "NOT_ALLOWED"); expect_match(conditionMessage(err), "huggingface")
  expect_true(dragonfarm:::outbound_check("https://huggingface.co", "publish", runs_dir = runs))
  blocked <- dragonfarm:::store_events(1, kind = "outbound", runs_dir = runs)
  expect_true(blocked$ok == 1)
  expect_equal(sum(dragonfarm:::store_events(10, kind = "outbound", runs_dir = runs)$code %in% "NOT_ALLOWED"), 1)
})

test_that("a blocked web page is refused before anything is fetched", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  no_outbound(runs)
  testthat::local_mocked_bindings(run_python = function(...) stop("Python should not run"))
  err <- tryCatch(dragon_documents("https://example.com/faq", name = "web", runs_dir = runs), error = function(e) e)
  expect_equal(err$code, "NOT_ALLOWED")
  expect_match(conditionMessage(err), "No outside hosts")
})

test_that("a blocked Claude judge sends nothing", {
  skip_if_not_installed("httr2")
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  no_outbound(runs)
  sent <- FALSE
  testthat::local_mocked_bindings(anthropic_request = function(...) { sent <<- TRUE; NULL })
  judge <- dragon_llm_anthropic(api_key = "test-key")
  expect_error(judge(c("a", "b")), class = "dragonfarm_error")
  expect_false(sent)
})

test_that("the stored default policy still allows any host (null survives the round trip)", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::policy_current(runs)                       # stores version 1
  expect_null(dragonfarm:::policy_current(runs)$outbound$allowed_hosts)
  expect_true(dragonfarm:::outbound_check("https://api.anthropic.com", "test", runs_dir = runs))
  pol <- dragonfarm:::policy_default(); pol$agents$ops$tools <- list("list_runs")
  dragonfarm:::policy_set(pol, set_by = "admin", runs_dir = runs)
  expect_null(dragonfarm:::policy_current(runs)$outbound$allowed_hosts)
})

test_that("with outbound set to none, every path that sends data refuses before sending", {
  run_dir <- copy_fixture_run()
  runs <- dirname(run_dir)
  withr::local_options(dragonfarm.runs_dir = runs)
  withr::local_envvar(HF_TOKEN = "hf_test", KAGGLE_USERNAME = "u", KAGGLE_KEY = "k")
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  no_outbound(runs)
  reached <- character()
  zip <- tempfile(fileext = ".zip"); writeLines("x", zip)
  testthat::local_mocked_bindings(
    bundle_paths = function(run) list(zip = zip, bundle_dir = dirname(zip)),
    kaggle_dataset_metadata = function(run) list(id = "u/x"),
    kaggle_cli = function(...) { reached <<- c(reached, "kaggle"); list(ok = TRUE, out = "") },
    lightning_python = function(...) { reached <<- c(reached, "lightning"); list(ok = TRUE, out = "") },
    hf_token_present = function() { reached <<- c(reached, "huggingface"); TRUE }
  )
  code <- function(expr) tryCatch({ force(expr); "SENT" }, dragonfarm_error = function(e) e$code)
  server <- dragon_backend_server("https://models.example.com/v1", "m")
  expect_equal(code(dragonfarm:::chat_completion_request(server, list(list(role = "user", content = "hi")), 8, 0, 1)), "NOT_ALLOWED")
  expect_equal(code(dragon_publish(run_dir, "me/model")), "NOT_ALLOWED")
  expect_equal(code(dragonfarm:::kaggle_round_trip(run_dir)), "NOT_ALLOWED")
  expect_equal(code(dragonfarm:::lightning_round_trip(run_dir)), "NOT_ALLOWED")
  expect_equal(code(dragon_documents("https://example.com/page", name = "web", runs_dir = runs)), "NOT_ALLOWED")
  expect_equal(code(dragon_llm_anthropic(api_key = "sk-test")("hello")), "NOT_ALLOWED")
  for (svc in c("huggingface", "anthropic", "openrouter", "groq", "kaggle")) {
    expect_match(dragonfarm:::secret_check(svc)$message, "not checked", info = svc)   # a key is saved, not checked
  }
  expect_equal(reached, character())                                  # nothing got as far as the network
  ev <- dragonfarm:::store_events(100, kind = "outbound", runs_dir = runs)
  expect_true(nrow(ev) >= 11 && all(ev$code == "NOT_ALLOWED"))       # each refusal is in the record
})

test_that("the offline switch stops model downloads in every Python process; 'Nowhere' alone does not (D-13)", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  testthat::local_mocked_bindings(python_source_dir = function() "src")
  no_outbound(runs)                                                    # data may go nowhere
  expect_false("HF_HUB_OFFLINE" %in% names(dragonfarm:::python_env()))  # downloads still work
  pol <- dragonfarm:::policy_current(runs); pol$version <- NULL; pol$outbound$offline <- TRUE
  dragonfarm:::policy_set(pol, set_by = "admin", note = "air-gapped", runs_dir = runs)
  env <- dragonfarm:::python_env()
  expect_equal(unname(env["HF_HUB_OFFLINE"]), "1"); expect_equal(unname(env["TRANSFORMERS_OFFLINE"]), "1")
  expect_true(dragonfarm:::policy_from_inputs(pol, list(offline = TRUE, outbound = "any"))$outbound$offline)
})
