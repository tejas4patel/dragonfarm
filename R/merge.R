#' Merge the adapter into the base model
#'
#' Produces a standalone model directory that loads with plain transformers
#' and needs neither peft nor dragonfarm.
#'
#' @param run A `dragon_run` or run directory.
#' @param out_dir Where to write the merged model. Defaults to `merged/`
#'   inside the run directory.
#' @return The output path, invisibly.
#' @examples
#' if (interactive()) {
#' run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
#' dir <- dragon_merge(run)
#' }
#' @export
dragon_merge <- function(run, out_dir = NULL) {
  run <- dragon_run(run)
  target <- resolve_target(run)
  out_dir <- out_dir %||% run_path(run, "merged")
  cli::cli_alert_info("Merging adapter into {.val {target$model}}. This loads the full model on the CPU.")
  args <- c("--adapter", target$adapter, "--out", out_dir, "--model", target$model)
  for (p in target$base_adapters %||% character()) args <- c(args, "--base-adapter", p)
  if (isTRUE(target$trust_remote_code)) args <- c(args, "--trust-remote-code")
  require_gpu_free("Merging")
  res <- run_python("dragonfarm.merge", args)
  if (res$status != 0) python_failure_message(res, "Merge")
  cli::cli_alert_success("Merged model written to {.path {out_dir}}.")
  invisible(normalizePath(out_dir, winslash = "/"))
}

#' Export a merged model to GGUF
#'
#' Converts a merged model directory to GGUF for use with llama.cpp, Ollama,
#' and similar runtimes. Requires a llama.cpp checkout; point the
#' `LLAMA_CPP_DIR` environment variable at it.
#'
#' @param merged_dir A merged model directory from [dragon_merge()].
#' @param out_file Output path. Defaults to `model-<quant>.gguf` next to the model.
#' @param quant Output type passed to the converter, such as `"q8_0"`, `"f16"`, or `"bf16"`.
#' @param llama_cpp_dir Path to a llama.cpp checkout containing `convert_hf_to_gguf.py`.
#' @return The output path, invisibly.
#' @examples
#' if (interactive()) {
#' run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
#' dragon_export_gguf(dragon_merge(run))
#' }
#' @export
dragon_export_gguf <- function(merged_dir, out_file = NULL, quant = "q8_0",
                               llama_cpp_dir = Sys.getenv("LLAMA_CPP_DIR", unset = "")) {
  check_string(merged_dir, "merged_dir")
  if (!dir.exists(merged_dir)) cli::cli_abort("{.path {merged_dir}} does not exist.")
  script <- file.path(llama_cpp_dir, "convert_hf_to_gguf.py")
  if (!nzchar(llama_cpp_dir) || !file.exists(script)) {
    cli::cli_abort(c(
      "llama.cpp converter not found.",
      "i" = "Clone {.url https://github.com/ggml-org/llama.cpp} and set {.envvar LLAMA_CPP_DIR} to the checkout.",
      "i" = "The converter needs {.code pip install -r requirements/requirements-convert_hf_to_gguf.txt} in the same Python."
    ))
  }
  out_file <- out_file %||% file.path(merged_dir, paste0("model-", quant, ".gguf"))
  py <- dragon_python()
  res <- processx::run(py, c(script, merged_dir, "--outfile", out_file, "--outtype", quant),
                       env = python_env(), error_on_status = FALSE, windows_hide_window = TRUE)
  if (res$status != 0) python_failure_message(res, "GGUF export")
  cli::cli_alert_success("GGUF written to {.path {out_file}}.")
  invisible(out_file)
}
