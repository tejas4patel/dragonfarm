#' Push a run's model to the Hugging Face Hub
#'
#' Uploads a run's model as a repo on the Hugging Face Hub, ready for any
#' hosted inference: a dedicated Inference Endpoint behind
#' [dragon_backend_server()], `transformers-cli`, or any tool that loads a
#' model by repo id. The repo is created if it does not exist.
#'
#' @param run A `dragon_run` or run directory.
#' @param repo A repo id, `"username/name"`.
#' @param what What to push. `"merged"` folds the adapter into the base
#'   model first (merging it if that has not been done yet), so the repo
#'   loads with plain transformers and needs neither `peft` nor
#'   dragonfarm; this is the usual choice for hosted inference. `"adapter"`
#'   pushes just the LoRA weights: a small, fast upload, but the base model
#'   and `peft` are needed to load it.
#' @param private Create the repo as private.
#' @param commit_message Defaults to a message naming the run and the stage.
#' @return The repo URL, invisibly.
#' @export
#' @examples
#' if (interactive()) {
#' dragon_publish(run, "yourname/support-agent-0.5b")
#' dragon_publish(run, "yourname/support-agent-0.5b-adapter", what = "adapter")
#' }
dragon_publish <- function(run, repo, what = c("merged", "adapter"), private = FALSE, commit_message = NULL) {
  run <- dragon_run(run)
  what <- match.arg(what)
  check_string(repo, "repo")
  if (!grepl("^[^/[:space:]]+/[^/[:space:]]+$", repo)) {
    cli::cli_abort("{.arg repo} must look like {.val username/name}.")
  }
  outbound_check("https://huggingface.co", sprintf("publish the %s model to %s (%s)", what, repo,
                                                  if (isTRUE(private)) "private" else "public"))
  if (!hf_token_present()) {
    cli::cli_abort(c(
      "No Hugging Face token found.",
      "i" = "Set {.envvar HF_TOKEN} to a token with write access (create one at {.url https://huggingface.co/settings/tokens}), then try again."
    ))
  }

  dir <- if (identical(what, "merged")) {
    merged <- run_path(run, "merged")
    if (!file.exists(file.path(merged, "config.json"))) {
      cli::cli_alert_info("No merged model in this run yet; merging first.")
      merged <- dragon_merge(run)
    }
    merged
  } else {
    resolve_target(run)$adapter
  }

  msg <- commit_message %||% sprintf("Push %s from dragonfarm run %s", what, run$id)
  args <- c("--dir", dir, "--repo", repo, "--commit-message", msg)
  if (isTRUE(private)) args <- c(args, "--private")
  cli::cli_alert_info("Uploading {.path {dir}} to {.val {repo}}. A merged model can take a while.")
  res <- run_python("dragonfarm.publish", args)
  if (res$status != 0) python_failure_message(res, "Publish")
  url <- sprintf("https://huggingface.co/%s", repo)
  cli::cli_alert_success("Published to {.url {url}}.")
  invisible(url)
}
