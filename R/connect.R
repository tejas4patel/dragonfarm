# Connecting a service (A11). Sign-in always happens in the person's own
# browser, never inside dragonfarm: providers forbid embedding their login
# pages. Where the provider supports it (OpenRouter), the browser hands the
# key straight back to a short-lived listener on this computer, so nothing is
# copied or pasted; elsewhere the exact key page opens and one paste follows.
# Either way the key goes to the keychain (secret_save()) and is checked with
# one small call. Internal until the Setup page settles.

# PKCE (RFC 7636): a random verifier and its S256 challenge.
pkce_pair <- function() {
  rlang::check_installed("openssl", reason = "to sign in with OpenRouter.")
  chars <- c(LETTERS, letters, 0:9, "-", ".", "_", "~")
  verifier <- paste(chars[as.integer(openssl::rand_num(64) * length(chars)) + 1L], collapse = "")
  list(verifier = verifier, challenge = base64url(openssl::sha256(charToRaw(verifier))))
}

base64url <- function(raw) {
  b <- jsonlite::base64_enc(raw)
  gsub("=+$", "", chartr("+/", "-_", b))
}

openrouter_auth_url <- function(callback, challenge, state) {
  paste0("https://openrouter.ai/auth?",
         "callback_url=", utils::URLencode(callback, reserved = TRUE),
         "&code_challenge=", challenge, "&code_challenge_method=S256",
         "&state=", state, "&key_label=dragonfarm")
}

# Swap the one-time code for a key (the only call that leaves the machine).
openrouter_exchange <- function(code, verifier, runs_dir = dragon_runs_dir()) {
  rlang::check_installed("httr2", reason = "to sign in with OpenRouter.")
  url <- "https://openrouter.ai/api/v1/auth/keys"
  outbound_check(url, "connect OpenRouter: exchange the sign-in code for a key", runs_dir = runs_dir)
  resp <- httr2::request(url) |>
    httr2::req_body_json(list(code = code, code_verifier = verifier, code_challenge_method = "S256")) |>
    httr2::req_error(is_error = function(resp) FALSE) |> httr2::req_timeout(30) |> httr2::req_perform()
  if (httr2::resp_status(resp) >= 400) {
    cli::cli_abort("OpenRouter did not accept the sign-in (HTTP {httr2::resp_status(resp)}). Try connecting again.",
                   class = "dragonfarm_error", code = "NOT_CONNECTED")
  }
  key <- httr2::resp_body_json(resp)$key
  if (!is.character(key) || !nzchar(key)) {
    cli::cli_abort("OpenRouter answered without a key. Try connecting again.", class = "dragonfarm_error", code = "NOT_CONNECTED")
  }
  key
}

# Wait for the browser to come back to http://localhost:<port>/callback.
# `open` opens the sign-in page (the system browser; tests pass their own).
await_callback <- function(make_url, open = utils::browseURL, wait = 300) {
  rlang::check_installed("httpuv", reason = "to receive the sign-in from your browser.")
  got <- NULL
  page <- paste0("<!doctype html><meta charset=utf-8><title>dragonfarm</title>",
                 "<body style=\"font-family:system-ui,sans-serif;margin:3rem\"><h1>Connected</h1>",
                 "<p>You can close this tab and go back to dragonfarm.</p>")
  port <- httpuv::randomPort()
  server <- httpuv::startServer("127.0.0.1", port, list(call = function(req) {
    if (!identical(req$PATH_INFO, "/callback")) return(list(status = 404L, headers = list(), body = "Not found"))
    q <- shiny::parseQueryString(req$QUERY_STRING %||% "")
    if (is.null(got)) got <<- q
    list(status = 200L, headers = list("Content-Type" = "text/html; charset=utf-8"), body = page)
  }))
  on.exit(httpuv::stopServer(server), add = TRUE)
  open(make_url(sprintf("http://localhost:%d/callback", port)))   # the form OpenRouter documents
  t0 <- Sys.time()
  while (is.null(got) && as.numeric(difftime(Sys.time(), t0, units = "secs")) < wait) httpuv::service(100)
  got
}

wait_label <- function(secs) if (secs >= 120) sprintf("%d minutes", round(secs / 60)) else sprintf("%d seconds", round(secs))

connect_openrouter <- function(open = utils::browseURL, wait = 300, runs_dir = dragon_runs_dir()) {
  pk <- pkce_pair()
  state <- base64url(openssl::rand_bytes(16))
  cli::cli_text("Finish signing in to OpenRouter in your browser; dragonfarm is waiting (up to {wait_label(wait)}).")
  got <- await_callback(function(cb) openrouter_auth_url(cb, pk$challenge, state), open = open, wait = wait)
  if (is.null(got)) {
    cli::cli_abort("No answer from the browser within {wait_label(wait)}. Nothing was saved.",
                   class = "dragonfarm_error", code = "NOT_CONNECTED")
  }
  if (!identical(got$state, state) || is.null(got$code) || !nzchar(got$code)) {
    cli::cli_abort("The sign-in that came back does not match the one dragonfarm started. Nothing was saved.",
                   class = "dragonfarm_error", code = "NOT_CONNECTED")
  }
  key <- openrouter_exchange(got$code, pk$verifier, runs_dir = runs_dir)
  secret_save("openrouter", list(OPENROUTER_API_KEY = key))
  secret_check("openrouter")
}

# Any known service: OpenRouter signs in through the browser; the others open
# their key page and take one paste (masked when possible).
connect_service <- function(service, open = utils::browseURL, ask = ask_secret, wait = 300, runs_dir = dragon_runs_dir()) {
  s <- secret_catalog()[[service]]
  if (is.null(s)) {
    cli::cli_abort("Unknown service {.val {service}}. Known: {paste(names(secret_catalog()), collapse = ', ')}.",
                   class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  if (identical(service, "openrouter")) return(connect_openrouter(open = open, wait = wait, runs_dir = runs_dir))
  open(s$get_url)
  values <- stats::setNames(lapply(s$vars, function(v) ask(sprintf("%s %s: ", s$title, settings_label(v)))), s$vars)
  if (!all(vapply(values, function(x) is.character(x) && nzchar(trimws(x)), TRUE))) {
    cli::cli_abort("Nothing was pasted, so nothing was saved.", class = "dragonfarm_error", code = "NOT_CONNECTED")
  }
  secret_save(service, values)
  secret_check(service)
}

ask_secret <- function(prompt) {
  if (requireNamespace("askpass", quietly = TRUE)) askpass::askpass(prompt) else readline(prompt)
}
