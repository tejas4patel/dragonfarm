test_that("PKCE follows RFC 7636 (its own test vector) and makes a fresh verifier each time", {
  skip_if_not_installed("openssl")
  v <- "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  expect_equal(dragonfarm:::base64url(openssl::sha256(charToRaw(v))), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  a <- dragonfarm:::pkce_pair(); b <- dragonfarm:::pkce_pair()
  expect_equal(nchar(a$verifier), 64)
  expect_match(a$verifier, "^[A-Za-z0-9._~-]+$")
  expect_false(identical(a$verifier, b$verifier))
  expect_equal(a$challenge, dragonfarm:::base64url(openssl::sha256(charToRaw(a$verifier))))
})

test_that("the OpenRouter sign-in address carries the local callback, the challenge and the state", {
  u <- dragonfarm:::openrouter_auth_url("http://127.0.0.1:5123/callback", "CHAL", "ST")
  expect_match(u, "^https://openrouter.ai/auth\\?")
  expect_match(u, "callback_url=http%3A%2F%2F127.0.0.1%3A5123%2Fcallback", fixed = TRUE)
  expect_match(u, "code_challenge=CHAL&code_challenge_method=S256&state=ST", fixed = TRUE)
})

# A stand-in for the person's browser: after "signing in" it calls the local
# callback from a separate process, as a real browser would.
fake_browser <- function(code = "one-time-code", state = NULL) {
  function(url) {
    q <- shiny::parseQueryString(sub("^[^?]*\\?", "", url))
    cb <- q$callback_url
    st <- state %||% q$state
    target <- sprintf("%s?code=%s&state=%s", cb, code, st)
    processx::process$new(Sys.which("curl"), c("-s", "-o", if (.Platform$OS.type == "windows") "NUL" else "/dev/null", target))
    invisible(TRUE)
  }
}

test_that("connecting OpenRouter takes the code from the browser, saves the key, and checks it", {
  skip_on_cran(); skip_if_not_installed("httpuv"); skip_if_not_installed("openssl"); skip_if(!nzchar(Sys.which("curl")), "no curl")
  clean_env(); store <- fake_keychain()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  seen <- NULL
  testthat::local_mocked_bindings(
    openrouter_exchange = function(code, verifier, runs_dir) { seen <<- list(code = code, verifier = verifier); "sk-or-test-key" },
    secret_check = function(service) list(ok = TRUE, message = "Connected.")
  )
  r <- dragonfarm:::connect_openrouter(open = fake_browser(), wait = 20)
  expect_true(r$ok)
  expect_equal(seen$code, "one-time-code")
  expect_equal(nchar(seen$verifier), 64)
  expect_equal(store$OPENROUTER_API_KEY, "sk-or-test-key")
  expect_equal(Sys.getenv("OPENROUTER_API_KEY"), "sk-or-test-key")
})

test_that("a sign-in that comes back with the wrong state is refused and nothing is saved", {
  skip_on_cran(); skip_if_not_installed("httpuv"); skip_if_not_installed("openssl"); skip_if(!nzchar(Sys.which("curl")), "no curl")
  clean_env(); store <- fake_keychain()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  testthat::local_mocked_bindings(openrouter_exchange = function(...) stop("must not be called"))
  err <- tryCatch(dragonfarm:::connect_openrouter(open = fake_browser(state = "forged"), wait = 20), error = function(e) e)
  expect_equal(err$code, "NOT_CONNECTED")
  expect_null(store$OPENROUTER_API_KEY)
})

test_that("no answer from the browser times out with nothing saved", {
  skip_on_cran(); skip_if_not_installed("httpuv"); skip_if_not_installed("openssl")
  clean_env(); store <- fake_keychain()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  err <- tryCatch(dragonfarm:::connect_openrouter(open = function(url) invisible(), wait = 1), error = function(e) e)
  expect_equal(err$code, "NOT_CONNECTED")
  expect_null(store$OPENROUTER_API_KEY)
})

test_that("other services open their key page and take one paste", {
  clean_env(); store <- fake_keychain()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  opened <- NULL
  testthat::local_mocked_bindings(secret_check = function(service) list(ok = TRUE, message = "Connected."))
  r <- dragonfarm:::connect_service("groq", open = function(u) opened <<- u, ask = function(prompt) "gsk_pasted")
  expect_equal(opened, "https://console.groq.com/keys")
  expect_equal(store$GROQ_API_KEY, "gsk_pasted")
  expect_true(r$ok)
  err <- tryCatch(dragonfarm:::connect_service("groq", open = function(u) NULL, ask = function(p) ""), error = function(e) e)
  expect_equal(err$code, "NOT_CONNECTED")
  expect_error(dragonfarm:::connect_service("nope"), class = "dragonfarm_error")
})

test_that("the code exchange goes through the outbound check", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  pol <- dragonfarm:::policy_current(runs); pol$outbound$allowed_hosts <- list()
  dragonfarm:::policy_set(pol, set_by = "test", runs_dir = runs)
  err <- tryCatch(dragonfarm:::openrouter_exchange("c", "v", runs_dir = runs), error = function(e) e)
  expect_equal(err$code, "NOT_ALLOWED")
})
