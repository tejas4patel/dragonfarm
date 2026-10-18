#' Serve a run's model with Ollama
#'
#' Merges the adapter into the base model (if not done already), registers
#' the result with Ollama, and checks that Ollama can answer with it. The
#' returned backend points [dragon_generate()] and [dragon_chat()] at it.
#'
#' Recent Ollama versions import safetensors through their MLX engine. With
#' Ollama 0.40.5 on Windows the import worked but the model could not answer
#' ("MLX runtime is not available"), for Qwen and SmolLM2 runs alike; other
#' systems were not tested. When that happens the unusable copy is removed
#' and the error says so. A GGUF file made with [dragon_export_gguf()]
#' (which needs llama.cpp) is the other route into Ollama.
#'
#' Needs Ollama installed and its service running. The `ollama` command is
#' looked for on the PATH and then in Ollama's usual install folders.
#'
#' @param run A `dragon_run`, or a merged model directory.
#' @param name Model name to register. Defaults to `dragonfarm-<run id>`.
#' @param quantize Optional Ollama quantization such as `"q8_0"` or `"q4_K_M"`
#'   to shrink the served model.
#' @param ollama Path to the `ollama` executable.
#' @return A `dragon_backend` for the served model.
#' @export
#' @examples
#' if (interactive()) {
#' backend <- dragon_serve_ollama(run)
#' options(dragonfarm.backend = backend)
#' dragon_chat(run)$say("Hello")
#' }
dragon_serve_ollama <- function(run, name = NULL, quantize = NULL, ollama = ollama_path()) {
  if (!nzchar(ollama)) {
    cli::cli_abort(c("Ollama was not found on the PATH.", "i" = "Install it from {.url https://ollama.com/download}, then try again."))
  }
  merged <- if (inherits(run, "dragon_run") || (is.character(run) && file.exists(file.path(run, "config.json")) && !file.exists(file.path(run, "model.safetensors")))) {
    r <- dragon_run(run)
    dir <- run_path(r, "merged")
    if (!file.exists(file.path(dir, "config.json"))) dragon_merge(r) else dir
  } else {
    run
  }
  merged <- normalizePath(merged, winslash = "/")
  name <- name %||% paste0("dragonfarm-", if (inherits(run, "dragon_run")) slugify(run$id) else slugify(basename(merged)))
  modelfile <- file.path(merged, "Modelfile")
  writeLines(ollama_modelfile(merged), modelfile)
  args <- c("create", name, "-f", modelfile)
  if (!is.null(quantize)) args <- c(args, "--quantize", quantize)
  cli::cli_alert_info("Registering {.val {name}} with Ollama from {.path {merged}}.")
  res <- processx::run(ollama, args, error_on_status = FALSE, windows_hide_window = TRUE)
  if (res$status != 0) {
    out <- paste(res$stdout, res$stderr)
    cli::cli_abort(c("{.code ollama create} failed (exit status {res$status}).",
                     "x" = "{paste(utils::tail(strsplit(out, '\n')[[1]], 10), collapse = '\n')}",
                     "i" = if (grepl("MLX", out)) "This Ollama imports safetensors through MLX, which does not support this model or this system. Export a GGUF file with {.fn dragon_export_gguf} instead."),
                   class = "dragonfarm_error")
  }
  # Registered is not the same as servable: ask for one token.
  problem <- ollama_try(name)
  if (!is.null(problem)) {
    processx::run(ollama, c("rm", name), error_on_status = FALSE, windows_hide_window = TRUE)
    cli::cli_abort(c("Ollama registered {.val {name}} but could not answer with it, so it was removed again.",
                     "x" = problem,
                     "i" = if (grepl("MLX", problem)) "This Ollama imports safetensors through MLX, which is not available on this system. Export a GGUF file with {.fn dragon_export_gguf} instead."),
                   class = "dragonfarm_error")
  }
  cli::cli_alert_success("Ollama serves {.val {name}}. Try {.code dragon_generate(run, \"Hello\", backend = dragon_backend_ollama(\"{name}\"))}.")
  dragon_backend_ollama(name)
}

# The ollama command: on the PATH, else where Ollama installs itself (an R
# session started before Ollama was installed has the old PATH).
ollama_path <- function() {
  p <- Sys.which("ollama")
  if (nzchar(p)) return(unname(p))
  local <- Sys.getenv("LOCALAPPDATA")
  candidates <- c(if (nzchar(local)) file.path(local, "Programs", "Ollama", "ollama.exe"),
                  "/Applications/Ollama.app/Contents/Resources/ollama", "/usr/local/bin/ollama", "/usr/bin/ollama")
  hit <- candidates[file.exists(candidates)]
  if (length(hit)) hit[[1]] else ""
}

# NULL when Ollama answers one token with the model, else the error text.
ollama_try <- function(name, url = "http://localhost:11434") {
  rlang::check_installed("httr2", reason = "to check the model Ollama serves.")
  resp <- tryCatch(httr2::req_perform(httr2::request(paste0(url, "/api/generate")) |>
                     httr2::req_body_json(list(model = name, prompt = "Hello", stream = FALSE, options = list(num_predict = 1))) |>
                     httr2::req_error(is_error = function(r) FALSE) |>
                     httr2::req_timeout(600)),
                   error = function(e) e)
  if (inherits(resp, "error")) return(conditionMessage(resp))
  body <- tryCatch(httr2::resp_body_json(resp), error = function(e) list())
  if (httr2::resp_status(resp) >= 400 || !is.null(body$error)) return(body$error %||% sprintf("HTTP %d", httr2::resp_status(resp)))
  NULL
}

ollama_modelfile <- function(merged_dir) {
  c(
    paste0("FROM ", merged_dir),
    "# Made by dragonfarm. The chat template comes from the model's tokenizer.",
    "PARAMETER temperature 0.7"
  )
}
