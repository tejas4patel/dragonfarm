# Free tiers (D-7: local model first, free tiers opt-in). A provider from
# inst/providers/providers.json is used only after a person opts in to it,
# with an optional daily cap; every request still goes through the outbound
# gateway and is recorded. A chain of backends falls back to the next one
# (normally the local model) when a provider refuses, fails, or reaches its
# cap, and records that it did.

provider_catalog <- function() {
  jsonlite::fromJSON(system.file("providers", "providers.json", package = "dragonfarm"), simplifyVector = FALSE)$providers
}

provider_info <- function(name) {
  p <- provider_catalog()[[name]]
  if (is.null(p)) {
    cli::cli_abort("There is no provider called {.val {name}}. Known: {paste(names(provider_catalog()), collapse = ', ')}.",
                   class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  p
}

# A person opts in (or out). Recorded as an event; the latest one counts.
provider_opt_in <- function(name, daily_cap = NULL, runs_dir = dragon_runs_dir()) {
  provider_info(name)
  if (!is.null(daily_cap)) check_number(daily_cap, "daily_cap", min = 1, integer = TRUE)
  store_record_event("provider_opt_in", name, ok = TRUE, detail = list(daily_cap = daily_cap), runs_dir = runs_dir)
  invisible(TRUE)
}

provider_opt_out <- function(name, runs_dir = dragon_runs_dir()) {
  provider_info(name)
  store_record_event("provider_opt_out", name, ok = TRUE, runs_dir = runs_dir)
  invisible(TRUE)
}

# list(opted_in, daily_cap, used_today) for a provider.
provider_status <- function(name, runs_dir = dragon_runs_dir()) {
  con <- store_open(runs_dir)
  last <- store_get(con, paste("SELECT kind, detail FROM events WHERE name = ? AND kind IN",
                                     "('provider_opt_in', 'provider_opt_out') ORDER BY id DESC LIMIT 1"), params = list(name))
  opted <- nrow(last) == 1 && identical(last$kind, "provider_opt_in")
  cap <- if (opted && !is.na(last$detail)) jsonlite::fromJSON(last$detail)$daily_cap else NULL
  host <- outbound_host(provider_info(name)$base_url)
  today <- format(Sys.time(), "%Y-%m-%d", tz = "UTC")
  # Only model requests count towards the cap, not listing the models.
  used <- store_get(con, paste("SELECT COUNT(*) AS n FROM events WHERE kind = 'outbound' AND name = ? AND ok = 1",
                               "AND substr(at, 1, 10) = ? AND detail LIKE '%\"purpose\":\"free tier:%'"),
                    params = list(host, today))$n
  list(opted_in = opted, daily_cap = cap, used_today = as.integer(used))
}

# A server backend for an opted-in provider. Refuses (NOT_OPTED_IN,
# QUOTA_REACHED, or a missing key) before anything is sent.
provider_backend <- function(name, model, runs_dir = dragon_runs_dir()) {
  p <- provider_check(name, runs_dir)
  key <- Sys.getenv(p$key_env, unset = "")
  if (!nzchar(key)) {
    cli::cli_abort(c("No {p$title} key found.", "i" = "Create one at {.url {p$sign_up}} and set {.envvar {p$key_env}}."),
                   class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  b <- dragon_backend_server(p$base_url, model, api_key_env = p$key_env)
  b$provider <- name
  b$runs_dir <- runs_dir
  b
}

# Checked when the backend is made and again before every request, so a long
# chat stops at the cap too.
provider_check <- function(name, runs_dir = dragon_runs_dir()) {
  p <- provider_info(name)
  st <- provider_status(name, runs_dir)
  if (!st$opted_in) {
    cli::cli_abort(c("Nothing is sent to {p$title} until you opt in to it.",
                     "i" = "Your questions and the excerpts they use would go to {p$title}'s servers."),
                   class = "dragonfarm_error", code = "NOT_OPTED_IN")
  }
  if (!is.null(st$daily_cap) && st$used_today >= st$daily_cap) {
    cli::cli_abort("The daily cap you set for {p$title} ({st$daily_cap} requests) has been reached.",
                   class = "dragonfarm_error", code = "QUOTA_REACHED")
  }
  invisible(p)
}

# Try backends in order; on failure use the next one, and record that.
backend_chain <- function(...) {
  backends <- list(...)
  if (!length(backends) || !all(vapply(backends, inherits, TRUE, "dragon_backend"))) {
    cli::cli_abort("{.fn backend_chain} needs one or more backends.")
  }
  structure(list(kind = "chain", backends = backends, model = backends[[1]]$model),
            class = c("dragon_backend_chain", "dragon_backend"))
}

#' @export
backend_generate.dragon_backend_chain <- function(backend, target, conversations, max_new_tokens = 256, temperature = 0.7,
                                                  top_p = 0.9, on_token = NULL, tools = NULL) {
  errors <- character()
  for (i in seq_along(backend$backends)) {
    b <- backend$backends[[i]]
    out <- tryCatch(backend_generate(b, target, conversations, max_new_tokens = max_new_tokens, temperature = temperature,
                                     top_p = top_p, on_token = on_token, tools = tools),
                    error = function(e) e)
    if (!inherits(out, "error")) {
      if (i > 1) {
        store_record_event("fallback", b$kind %||% "backend", ok = TRUE,
                           detail = list(used = i, errors = errors))
      }
      return(out)
    }
    errors <- c(errors, sprintf("%s: %s", b$provider %||% b$kind %||% "backend", conditionMessage(out)))
  }
  cli::cli_abort(c("Every backend failed.", stats::setNames(errors, rep("x", length(errors)))))
}

# A free-tier model as a judge or teacher (a function from prompts to
# replies, as as_llm() takes). The provider's backend is made only when the
# function is called, so a judge saved for a background pipeline holds a
# provider name and a model id, never a key; the opt-in, daily cap and
# outbound check apply on every call.
llm_provider <- function(name, model, system = NULL, max_new_tokens = 512, runs_dir = dragon_runs_dir()) {
  provider_info(name)
  check_string(model, "model")
  force(system); force(max_new_tokens); force(runs_dir)
  fn <- function(prompts, schema = NULL) {
    b <- provider_backend(name, model, runs_dir = runs_dir)
    dragon_generate(model, prompts, system = system, max_new_tokens = max_new_tokens, temperature = 0, backend = b)
  }
  attr(fn, "label") <- paste0(name, ":", model)
  fn
}

# The provider's current chat models (OpenRouter: only the free ones), for a
# picker in the app. Sends only the key, through the outbound check, and does
# not count towards the daily cap. character() when there is no key, the
# policy blocks the host, or the provider does not answer.
provider_models <- function(name, runs_dir = dragon_runs_dir()) {
  p <- provider_info(name)
  key <- Sys.getenv(p$key_env, unset = "")
  if (!nzchar(key) || !requireNamespace("httr2", quietly = TRUE)) return(character())
  url <- paste0(p$base_url, "/models")
  allowed <- tryCatch({ outbound_check(url, "list the provider's models", runs_dir = runs_dir); TRUE },
                      dragonfarm_error = function(e) FALSE)
  if (!allowed) return(character())
  body <- tryCatch(httr2::request(url) |>
                     httr2::req_headers(Authorization = paste("Bearer", key), .redact = "Authorization") |>
                     httr2::req_timeout(15) |> httr2::req_perform() |> httr2::resp_body_json(),
                   error = function(e) NULL)
  provider_model_ids(name, body)
}

provider_model_ids <- function(name, body) {
  ids <- unlist(lapply(body$data %||% list(), function(m) m[["id"]]))
  if (is.null(ids)) return(character())
  if (identical(name, "openrouter")) ids <- ids[endsWith(ids, ":free")]
  # Speech, safety-classifier and voice models cannot answer questions.
  ids <- ids[!grepl("whisper|guard|orpheus|tts|embed", ids, ignore.case = TRUE)]
  sort(unique(ids))
}
