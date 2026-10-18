#' Fine-tune a model with LoRA
#'
#' Writes a run directory, then launches the trainer as a background Python
#' process. Returns immediately unless `wait = TRUE`. The run survives the R
#' session; reopen it later with [dragon_run()].
#'
#' @param dataset A mapped `dragon_dataset` (see [dragon_map()]).
#' @param model A Hugging Face model id such as
#'   `"HuggingFaceTB/SmolLM2-135M-Instruct"`, a local model directory, or a
#'   finished `dragon_run` to continue from. In the last case the earlier
#'   run's adapters are folded into the weights before this run adds its own,
#'   so stages chain: fine-tune, then [dragon_prefer()], and so on. See
#'   [dragon_presets()] for model ids.
#' @param lora LoRA settings from [dragon_lora()].
#' @param args Training settings from [dragon_train_args()].
#' @param hardware Hardware settings from [dragon_hardware()].
#' @param name Short label used in the run id. Defaults to the model name.
#' @param run_dir Exact directory to use. Defaults to a timestamped directory
#'   under `runs_dir`.
#' @param runs_dir Parent directory for runs. See [dragon_runs_dir()].
#' @param n_samples Number of held-out rows to generate sample replies for
#'   at the end of training.
#' @param revision Model revision (branch, tag, or commit) on the Hub.
#' @param trust_remote_code Allow the model repository to run custom code.
#' @param wait Block until training finishes.
#' @return A `dragon_run` object.
#' @export
#' @examples
#' if (interactive()) {
#' run <- dragon_dataset(dragon_example_data()) |>
#'   dragon_map(prompt = "{subject}\n\n{body}", response = "reply") |>
#'   dragon_train("HuggingFaceTB/SmolLM2-135M-Instruct", wait = TRUE)
#' dragon_generate(run, "My order arrived damaged.")
#' }
dragon_train <- function(dataset, model, lora = dragon_lora(), args = dragon_train_args(),
                         hardware = dragon_hardware(), name = NULL, run_dir = NULL,
                         runs_dir = dragon_runs_dir(), n_samples = 10,
                         revision = NULL, trust_remote_code = FALSE, wait = FALSE) {
  hits <- tryCatch(dataset_pii(dataset), error = function(e) NULL)
  if (!is.null(hits) && nrow(hits)) {
    cli::cli_warn(c("The training rows hold likely personal data: {pii_counts(hits)}.",
                    "i" = "Review them before training; the app's Train step lists every hit."))
  }
  prep <- prepare_run(dataset, model, lora, args, hardware, name, run_dir, runs_dir, n_samples,
                      revision = revision, trust_remote_code = trust_remote_code)
  files <- prep$files
  cpu_hint(hardware)
  run <- launch_trainer(prep$run_dir)
  cli::cli_alert_success("Launched run {.strong {run$id}} ({files$n_train} training rows, {files$n_eval} held out).")
  cli::cli_text("Check on it with {.code dragon_status(run)}, {.code dragon_progress(run)}, or {.code dragon_wait(run)}.")
  if (wait) dragon_wait(run) else run
}

# Validate the inputs and write a run directory without launching anything.
# Shared by dragon_train() and dragon_bundle(). Returns list(run_dir, files).
prepare_run <- function(dataset, model, lora, args, hardware, name, run_dir, runs_dir, n_samples,
                        revision = NULL, trust_remote_code = FALSE, state = "queued",
                        check_token = TRUE, stage = "sft", prefer = NULL, reinforce = NULL) {
  kind <- switch(stage, prefer = "pairs", reinforce = "prompts", "messages")
  check_dataset(dataset, mapped = TRUE, kind = kind)
  base <- resolve_base(model)
  model <- base$model
  if (!is.null(base$run_id)) {
    trust_remote_code <- isTRUE(trust_remote_code) || isTRUE(base$trust_remote_code)
    revision <- revision %||% base$revision
  }
  if (!inherits(lora, "dragon_lora")) cli::cli_abort("{.arg lora} must come from {.fn dragon_lora}.")
  if (!inherits(args, "dragon_train_args")) cli::cli_abort("{.arg args} must come from {.fn dragon_train_args}.")
  if (!inherits(hardware, "dragon_hardware")) cli::cli_abort("{.arg hardware} must come from {.fn dragon_hardware}.")
  check_number(n_samples, "n_samples", min = 0, integer = TRUE)

  preset <- preset_for(model)
  if (!is.null(preset) && preset$gated && !hf_token_present() && !isTRUE(getOption("dragonfarm.skip_token_check"))) {
    if (check_token) {
      cli::cli_abort(c(
        "{.val {model}} is a gated model and no Hugging Face token was found.",
        "i" = "Accept the license on huggingface.co, then set {.envvar HF_TOKEN} before training.",
        "i" = "Set {.code options(dragonfarm.skip_token_check = TRUE)} if the token is configured another way."
      ))
    } else {
      cli::cli_alert_warning("{.val {model}} is gated. The cloud notebook needs a Hugging Face token stored as a secret named {.envvar HF_TOKEN}.")
    }
  }

  if (is.null(run_dir)) {
    suffix <- switch(stage, prefer = paste0("-", prefer$method), reinforce = "-grpo", "")
    default_name <- paste0(basename(model), suffix)
    run_dir <- unique_run_dir(runs_dir, name %||% default_name)
  }
  if (file.exists(file.path(run_dir, "config.json"))) {
    cli::cli_abort("{.path {run_dir}} already holds a run. Pick another {.arg run_dir} or use {.fn dragon_resume}.")
  }
  dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)
  run_dir <- normalizePath(run_dir, winslash = "/")

  # Earlier-stage adapters travel with the run, so it stays self-contained
  # (and bundles for the cloud) without shipping merged weights.
  rel_adapters <- character()
  for (i in seq_along(base$adapters)) {
    rel <- sprintf("base_adapters/%d", i)
    dst <- file.path(run_dir, rel)
    dir.create(dst, recursive = TRUE, showWarnings = FALSE)
    file.copy(list.files(base$adapters[i], full.names = TRUE), dst, recursive = TRUE)
    rel_adapters <- c(rel_adapters, rel)
  }

  if (!is.null(reinforce)) reinforce$rewards <- localize_rewards(reinforce$rewards, run_dir)

  files <- write_dataset_files(dataset, run_dir)
  cfg <- build_config(basename(run_dir), model, files, lora, args, hardware, n_samples,
                      revision = revision, trust_remote_code = trust_remote_code,
                      stage = stage, prefer = prefer, reinforce = reinforce,
                      base = list(run_id = base$run_id, adapters = rel_adapters))
  write_json(cfg, file.path(run_dir, "config.json"))
  write_json(
    list(source = dataset$source, name = dataset$name, mapping = dataset$mapping,
         split = list(eval_frac = dataset$split$eval_frac, seed = dataset$split$seed),
         documents = dataset$documents),
    file.path(run_dir, "dataset.json")
  )
  write_json(list(state = state, created_at = now_iso(), pid = NULL), file.path(run_dir, "status.json"))
  # Who created the run, from what; a personal-data approval given in the app
  # travels with it (option set around the launch).
  store_record_event("run_created", basename(run_dir), ok = TRUE, runs_dir = runs_dir,
                     detail = list(state = state, model = model, revision = revision,
                                   train_md5 = file_md5(file.path(run_dir, files$train)),
                                   documents = dataset$documents$set, personal_data = getOption("dragonfarm.approval"),
                                   personal_data_rows = pii_rows(dataset)))
  writeLines(character(), file.path(run_dir, "log.txt"))
  list(run_dir = run_dir, files = files)
}

# Timestamped run directory that does not exist yet. Ids have one-second
# resolution, so two runs started in the same second get a numeric suffix.
unique_run_dir <- function(runs_dir, name) {
  base <- file.path(runs_dir, make_run_id(name))
  candidate <- base
  i <- 1L
  while (dir.exists(candidate)) {
    i <- i + 1L
    candidate <- paste0(base, "-", i)
  }
  candidate
}

# What a stage starts from: a model id or path, plus the ordered adapters of
# the run it continues (each adapter's parents first, then its own).
resolve_base <- function(model) {
  if (inherits(model, "dragon_run")) {
    cfg <- run_config(model)
    adapter <- run_path(model, "adapter")
    if (!file.exists(file.path(adapter, "adapter_config.json"))) {
      st <- dragon_status(model)
      cli::cli_abort("Run {.strong {model$id}} has no adapter to start from (state: {st$state}).")
    }
    parents <- vapply(cfg$model$base_adapters %||% list(), function(p) run_path(model, p), character(1))
    return(list(
      model = cfg$model$id, adapters = c(parents, adapter), run_id = model$id,
      trust_remote_code = isTRUE(cfg$model$trust_remote_code), revision = cfg$model$revision
    ))
  }
  check_string(model, "model")
  list(model = model, adapters = character(), run_id = NULL, trust_remote_code = NULL, revision = NULL)
}

# One line pointing at cloud GPUs when this machine is already known to be
# CPU-only (from an earlier dragon_check() or the app's hardware probe).
cpu_hint <- function(hardware) {
  hw <- the$hardware
  if (is.null(hw) || !identical(hw$device, "cpu") || !identical(hardware$device, "auto")) return(invisible(FALSE))
  cli::cli_alert_info("No GPU on this machine, so training runs on the CPU. For a cloud GPU, use {.fn dragon_bundle} and {.fn dragon_remote} instead.")
  invisible(TRUE)
}

launch_trainer <- function(run_dir, resume = FALSE) {
  py <- dragon_python()
  log <- file.path(run_dir, "log.txt")
  args <- c("-m", "dragonfarm.train", "--run-dir", run_dir)
  if (resume) args <- c(args, "--resume")
  # Two heavy Python/CUDA processes starting at the same moment have crashed
  # a fresh trainer process on Windows (STATUS_DLL_INIT_FAILED, exit
  # -1073741502) the local inference worker being the usual culprit, since
  # it can be sitting there from an earlier Try it or Chat call. Freeing it
  # first also gives the trainer the GPU memory it was holding.
  if (worker_alive()) {
    cli::cli_alert_info("Stopping the local inference worker before training starts, to avoid two heavy processes racing for the GPU.")
    dragon_worker_stop()
  }
  require_gpu_free("Training")
  warn_other_workers("Training")
  p <- processx::process$new(
    py, args,
    stdout = log_target(log, resume), stderr = "2>&1",
    env = python_env(),
    cleanup = FALSE, cleanup_tree = FALSE,
    windows_hide_window = TRUE
  )
  new_run(run_dir, p)
}

# Where a trainer's output goes. A resume adds to the run's log instead of
# replacing it: processx 3.9.0 and later append with ">>"; with older ones the
# earlier log is kept beside it as log-before-<time>.txt.
log_target <- function(log, resume, append_ok = utils::packageVersion("processx") >= "3.9.0") {
  if (!resume || !file.exists(log)) return(log)
  if (append_ok) return(paste0(">>", log))
  file.copy(log, sub("\\.txt$", format(Sys.time(), "-before-%Y%m%d-%H%M%S.txt"), log))
  log
}

#' Resume a run from its latest checkpoint
#'
#' Useful after a cancel or a crash. Continues with the same configuration.
#'
#' @param run A `dragon_run`.
#' @param wait Block until training finishes.
#' @return A `dragon_run` object.
#' @export
dragon_resume <- function(run, wait = FALSE) {
  run <- dragon_run(run)
  st <- dragon_status(run)
  if (st$state %in% c("queued", "running")) cli::cli_abort("Run {.strong {run$id}} is still {st$state}.")
  ck <- list.dirs(run_path(run, "checkpoints"), recursive = FALSE)
  if (!length(ck)) cli::cli_alert_warning("No checkpoint found; training restarts from the beginning.")
  unlink(run_path(run, "cancel.request"))
  st$state <- "queued"
  st$error <- NULL
  st$finished_at <- NULL
  write_json(st, run_path(run, "status.json"))
  append_log(run_path(run, "log.txt"), sprintf("\n[dragonfarm] ---- resumed %s ----", now_iso()))
  run <- launch_trainer(run$dir, resume = TRUE)
  cli::cli_alert_success("Resumed run {.strong {run$id}}.")
  if (wait) dragon_wait(run) else run
}
