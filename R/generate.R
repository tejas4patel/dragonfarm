#' Generate replies from a fine-tuned model
#'
#' Runs through the session's inference backend: by default a local Python
#' worker that keeps the last models loaded, so only the first call pays the
#' load. Pass a server backend to generate from Ollama or any
#' OpenAI-compatible endpoint instead. See [dragon_backend].
#'
#' @param x A `dragon_run`, a run directory, an adapter directory, a merged
#'   model directory, or a Hugging Face model id.
#' @param prompt One or more user prompts.
#' @param system Optional system prompt.
#' @param max_new_tokens Maximum tokens to generate per reply.
#' @param temperature Sampling temperature. `0` means greedy decoding.
#' @param top_p Nucleus sampling threshold.
#' @param base Ignore this run's adapter and generate from what it started
#'   with: the base model, or the earlier run it continued from. Useful for
#'   before-and-after comparisons.
#' @param backend Where to run inference. See [dragon_backend]. Server
#'   backends serve a fixed model and ignore `x`.
#' @return A character vector, one reply per prompt.
#' @examples
#' if (interactive()) {
#' dragon_generate("HuggingFaceTB/SmolLM2-135M-Instruct", "Say hello in five words.")
#' }
#' @export
dragon_generate <- function(x, prompt, system = NULL, max_new_tokens = 256,
                            temperature = 0.7, top_p = 0.9, base = FALSE, backend = dragon_backend()) {
  if (!is.character(prompt) || !length(prompt)) cli::cli_abort("{.arg prompt} must be a character vector.")
  if (!inherits(backend, "dragon_backend")) cli::cli_abort("{.arg backend} must be a {.cls dragon_backend}.")
  target <- NULL
  if (!is_server_backend(backend)) {
    target <- resolve_target(x)
    if (isTRUE(base)) target$adapter <- NULL
  }
  conversations <- lapply(prompt, function(p) {
    msgs <- list()
    if (!is.null(system)) msgs <- c(msgs, list(list(role = "system", content = system)))
    c(msgs, list(list(role = "user", content = p)))
  })
  out <- backend_generate(backend, target, conversations, max_new_tokens = as.integer(max_new_tokens),
                          temperature = temperature, top_p = top_p)
  vapply(out, function(o) as.character(o %||% ""), character(1))
}

# Work out base model id and adapter path from whatever the user passed.
resolve_target <- function(x) {
  if (inherits(x, "dragon_run")) {
    cfg <- run_config(x)
    adapter <- run_path(x, "adapter")
    if (!file.exists(file.path(adapter, "adapter_config.json"))) {
      st <- dragon_status(x)
      cli::cli_abort("Run {.strong {x$id}} has no saved adapter yet (state: {st$state}).")
    }
    base_adapters <- vapply(cfg$model$base_adapters %||% list(), function(p) run_path(x, p), character(1))
    return(list(model = cfg$model$id, revision = cfg$model$revision, adapter = adapter, base_adapters = base_adapters,
                trust_remote_code = cfg$model$trust_remote_code))
  }
  check_string(x, "x")
  if (dir.exists(x)) {
    x <- normalizePath(x, winslash = "/")
    if (file.exists(file.path(x, "config.json")) && file.exists(file.path(x, "adapter", "adapter_config.json"))) {
      return(resolve_target(dragon_run(x)))
    }
    if (file.exists(file.path(x, "adapter_config.json"))) {
      base <- read_json(file.path(x, "adapter_config.json"))$base_model_name_or_path
      return(list(model = base, revision = preset_revision(base), adapter = x, base_adapters = character(), trust_remote_code = FALSE))
    }
    if (file.exists(file.path(x, "config.json"))) {
      return(list(model = x, adapter = NULL, base_adapters = character(), trust_remote_code = FALSE))
    }
    cli::cli_abort("{.path {x}} is neither a run, an adapter, nor a model directory.")
  }
  list(model = x, revision = preset_revision(x), adapter = NULL, base_adapters = character(), trust_remote_code = FALSE)
}
