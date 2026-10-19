# Keys for outside services, kept in the computer's own keychain (Windows
# Credential Manager, macOS Keychain, the Secret Service on Linux) through the
# 'keyring' package: never in scripts, project files or the runs folder.
# When the app starts, saved keys are put into this R session's environment,
# where the rest of dragonfarm and its background processes already look,
# so nothing else needs to know where a key came from. A key already set in
# the environment (for example by an admin on Posit Connect) wins.

secret_service <- "dragonfarm"

# The keys dragonfarm knows, grouped by the service they unlock.
secret_catalog <- function() {
  list(
    huggingface = list(title = "Hugging Face", vars = "HF_TOKEN", get_url = "https://huggingface.co/settings/tokens",
                       why = "Gated models such as Llama and Gemma, and publishing your models."),
    anthropic = list(title = "Claude API", vars = "ANTHROPIC_API_KEY", get_url = "https://console.anthropic.com/settings/keys",
                     why = "Claude as a judge or question writer. Paid by your Anthropic account."),
    kaggle = list(title = "Kaggle", vars = c("KAGGLE_USERNAME", "KAGGLE_KEY"), get_url = "https://www.kaggle.com/settings",
                  why = "Train on Kaggle's free GPUs with one click."),
    lightning = list(title = "Lightning AI", vars = c("LIGHTNING_USER_ID", "LIGHTNING_API_KEY"), get_url = "https://lightning.ai/",
                     why = "Train on a Lightning GPU Studio with one click."),
    openrouter = list(title = "OpenRouter", vars = "OPENROUTER_API_KEY", get_url = "https://openrouter.ai/settings/keys",
                      why = "A free-tier model when this machine is too small (only after you opt in)."),
    groq = list(title = "Groq", vars = "GROQ_API_KEY", get_url = "https://console.groq.com/keys",
                why = "A free-tier model when this machine is too small (only after you opt in).")
  )
}

keychain_available <- function() is.null(keychain_problem())

# NULL when the keychain can be used; otherwise one plain sentence on why and
# what to do. 'keyring' is only suggested, so a fresh install often lacks it.
keychain_problem <- function(installed = requireNamespace("keyring", quietly = TRUE)) {
  if (!installed) {
    return("The keyring package is not installed. Run install.packages(\"keyring\") in the R console, then restart the app.")
  }
  err <- tryCatch({ keyring::default_backend(); NULL }, error = function(e) conditionMessage(e))
  if (is.null(err)) return(NULL)
  paste0("The keyring package cannot reach this computer's keychain (", err, "). Ask your admin to set the keys for you.")
}

# The only three places that touch the keychain.
keychain_get <- function(var) tryCatch(keyring::key_get(secret_service, var), error = function(e) NULL)
keychain_set <- function(var, value) keyring::key_set_with_value(secret_service, var, password = value)
keychain_delete <- function(var) try(keyring::key_delete(secret_service, var), silent = TRUE)

# Put saved keys into the environment, without overriding ones already set.
# Returns the names it loaded.
secrets_load <- function() {
  if (!keychain_available()) return(invisible(character()))
  loaded <- character()
  for (s in secret_catalog()) for (v in s$vars) {
    if (nzchar(Sys.getenv(v))) next
    val <- keychain_get(v)
    if (!is.null(val) && nzchar(val)) {
      do.call(Sys.setenv, stats::setNames(list(val), v))
      loaded <- c(loaded, v)
    }
  }
  invisible(loaded)
}

# Save one service's keys (a named list var -> value) to the keychain and
# this session.
secret_save <- function(service, values) {
  s <- secret_catalog()[[service]]
  if (is.null(s)) cli::cli_abort("Unknown service {.val {service}}.", class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  values <- lapply(values, function(x) trimws(x %||% ""))
  missing <- setdiff(s$vars, names(values)[vapply(values, nzchar, TRUE)])
  if (length(missing)) cli::cli_abort("Fill in {paste(missing, collapse = ' and ')}.", class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  problem <- keychain_problem()
  if (!is.null(problem)) {
    cli::cli_abort(c("Keys cannot be saved on this computer yet.", "i" = "{problem}"),
                   class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  for (v in s$vars) {
    keychain_set(v, values[[v]])
    do.call(Sys.setenv, stats::setNames(list(values[[v]]), v))
  }
  store_record_event("secret_saved", service, ok = TRUE, detail = list(vars = s$vars))   # names only, never values
  invisible(TRUE)
}

secret_remove <- function(service) {
  s <- secret_catalog()[[service]]
  for (v in s$vars) {
    if (keychain_available()) keychain_delete(v)
    Sys.unsetenv(v)
  }
  store_record_event("secret_removed", service, ok = TRUE)
  invisible(TRUE)
}

# list(set, where = "keychain" | "environment" | "none", masked) for a service.
secret_status <- function(service) {
  s <- secret_catalog()[[service]]
  vals <- vapply(s$vars, function(v) Sys.getenv(v), "")
  if (!all(nzchar(vals))) return(list(set = FALSE, where = "none", masked = ""))
  saved <- keychain_available() && all(vapply(s$vars, function(v) identical(keychain_get(v), Sys.getenv(v)), TRUE))
  last <- vals[[length(vals)]]
  list(set = TRUE, where = if (saved) "keychain" else "environment",
       masked = paste0("\u2022\u2022\u2022\u2022", substr(last, max(1, nchar(last) - 3), nchar(last))))
}

# A kaggle.json Kaggle has just downloaded (Settings > API > Create New
# Token): list(username, key, path), or NULL.
kaggle_json_download <- function(dir = downloads_dir()) {
  if (is.null(dir)) return(NULL)
  f <- list.files(dir, pattern = "^kaggle( \\([0-9]+\\))?[.]json$", full.names = TRUE)
  if (!length(f)) return(NULL)
  f <- f[which.max(file.mtime(f))]
  j <- tryCatch(jsonlite::read_json(f), error = function(e) NULL)
  if (is.null(j$username) || is.null(j$key)) return(NULL)
  list(username = j$username, key = j$key, path = f)
}

# One small call that proves a key works, sending nothing but the key to its
# own service. Returns list(ok, message). Lightning has no cheap check here;
# its keys are tested on the first training run.
secret_check <- function(service) {
  get <- function(v) Sys.getenv(v)
  # A key check contacts the service, so it passes the outbound check like
  # everything else; when the policy blocks it, the key is saved unchecked.
  r <- tryCatch(switch(service,
    huggingface = http_ok("https://huggingface.co/api/whoami-v2", list(Authorization = paste("Bearer", get("HF_TOKEN")))),
    anthropic = http_ok("https://api.anthropic.com/v1/models", list(`x-api-key` = get("ANTHROPIC_API_KEY"), `anthropic-version` = "2023-06-01")),
    openrouter = http_ok("https://openrouter.ai/api/v1/key", list(Authorization = paste("Bearer", get("OPENROUTER_API_KEY")))),
    groq = http_ok("https://api.groq.com/openai/v1/models", list(Authorization = paste("Bearer", get("GROQ_API_KEY")))),
    kaggle = {
      outbound_check("https://www.kaggle.com", "check that a saved key works")
      k <- kaggle_cli(c("kernels", "list", "--mine", "--page-size", "1"))
      list(ok = k$ok, status = if (k$ok) 200L else 401L)
    },
    lightning = return(list(ok = NA, message = "Saved. Lightning checks the keys when you first train there.")),
    return(list(ok = NA, message = "Saved."))
  ), dragonfarm_error = function(e) if (identical(e$code, "NOT_ALLOWED")) list(blocked = TRUE) else stop(e))
  if (isTRUE(r$blocked)) return(list(ok = NA, message = "Saved, not checked: the outbound policy does not allow contacting this service."))
  list(ok = isTRUE(r$ok), message = if (isTRUE(r$ok)) "Connected." else if (identical(r$status, 401L) || identical(r$status, 403L))
    "The service did not accept this key." else sprintf("Could not reach the service (%s).", r$status %||% "no answer"))
}

# GET a URL with headers through the outbound gateway; list(ok, status).
http_ok <- function(url, headers) {
  rlang::check_installed("httr2", reason = "to check keys.")
  outbound_check(url, "check that a saved key works")
  req <- httr2::request(url) |> httr2::req_error(is_error = function(resp) FALSE) |> httr2::req_timeout(20)
  req <- do.call(httr2::req_headers, c(list(req), headers, list(.redact = names(headers))))
  resp <- tryCatch(httr2::req_perform(req), error = function(e) NULL)
  if (is.null(resp)) return(list(ok = FALSE, status = NA_integer_))
  s <- httr2::resp_status(resp)
  list(ok = s >= 200 && s < 300, status = s)
}
