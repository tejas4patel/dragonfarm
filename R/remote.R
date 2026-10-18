# Hand a run to a cloud GPU and bring the results back.
#
# The run directory already is the whole contract between R and the trainer,
# so a run can be zipped, trained on any machine with a GPU, and its outputs
# copied back into place. Nothing in this file needs Python on the local
# machine.

remote_repo_url <- "https://github.com/tejas4patel/dragonfarm"
remote_notebook_file <- "dragonfarm_remote.ipynb"
remote_notebook_repo_path <- paste0("inst/remote/", remote_notebook_file)

notebook_github_url <- function() {
  paste0(remote_repo_url, "/blob/main/", remote_notebook_repo_path)
}

#' Cloud GPU providers
#'
#' Machines without a GPU can still fine-tune: [dragon_bundle()] packages a
#' run as a zip, [dragon_remote()] opens one of these providers with the
#' dragonfarm notebook, and [dragon_import()] brings the trained adapter
#' back. Google Colab and Kaggle have free GPU tiers. Lightning AI gives free
#' monthly credits. RunPod is pay per hour.
#'
#' @return A data frame with one row per provider: `provider` (the id to pass
#'   to [dragon_remote()]), `name`, `cost`, and `opens` (what the link opens).
#' @export
#' @examples
#' dragon_remote_providers()
dragon_remote_providers <- function() {
  data.frame(
    provider = c("colab", "kaggle", "lightning", "runpod"),
    name = c("Google Colab", "Kaggle", "Lightning AI", "RunPod"),
    cost = c(
      "Free tier with a T4; paid tiers for longer sessions",
      "Free: about 30 GPU hours a week (T4 x2 or P100)",
      "Free monthly credits, then pay as you go",
      "Pay per hour, wide choice of GPUs"
    ),
    opens = c(
      "The dragonfarm notebook, directly",
      "The dragonfarm notebook, directly",
      "The dragonfarm repository in a new Studio",
      "The RunPod console"
    ),
    stringsAsFactors = FALSE
  )
}

cloud_provider_choices <- function() {
  c("Google Colab (free tier)" = "colab", "Kaggle (free tier)" = "kaggle",
    "Lightning AI (free credits)" = "lightning", "RunPod (paid)" = "runpod")
}

provider_name <- function(provider) {
  p <- dragon_remote_providers()
  p$name[match(provider, p$provider)]
}

check_provider <- function(provider) {
  ok <- dragon_remote_providers()$provider
  if (!is.character(provider) || length(provider) != 1 || !provider %in% ok) {
    cli::cli_abort("{.arg provider} must be one of {.val {ok}}.")
  }
  provider
}

# Link that opens the provider with the hosted notebook (or repo) loaded.
remote_url <- function(provider) {
  check_provider(provider)
  nb <- notebook_github_url()
  switch(provider,
    colab = sub("^https://github.com/", "https://colab.research.google.com/github/", nb),
    kaggle = paste0("https://www.kaggle.com/kernels/welcome?src=", nb),
    lightning = paste0("https://lightning.ai/new?repo_url=", utils::URLencode(remote_repo_url, reserved = TRUE)),
    runpod = "https://console.runpod.io/deploy"
  )
}

# Where the bundle and provider helper files live inside a run directory.
bundle_paths <- function(run) {
  dir <- run_path(run, "remote")
  list(
    dir = dir,
    bundle_dir = file.path(dir, "bundle"),
    zip = file.path(dir, "bundle", sprintf("dragonfarm-%s.zip", run$id)),
    dataset_meta = file.path(dir, "bundle", "dataset-metadata.json"),
    notebook = file.path(dir, remote_notebook_file),
    kernel_meta = file.path(dir, "kernel-metadata.json"),
    readme = file.path(dir, "README.md")
  )
}

results_name <- function(run) sprintf("dragonfarm-results-%s.zip", run$id)

remote_notebook_source <- function() {
  f <- system.file("remote", remote_notebook_file, package = "dragonfarm")
  if (!nzchar(f)) cli::cli_abort("The bundled notebook is missing. Is dragonfarm installed correctly?")
  f
}

#' Package a run for a cloud GPU
#'
#' Writes a run directory exactly as [dragon_train()] would, but instead of
#' launching the trainer it zips everything a GPU machine needs: the data in
#' chat format, the configuration, the trainer's Python code, and a notebook
#' that runs it. Nothing is trained locally and Python is not needed.
#'
#' Continue with [dragon_remote()] to open a provider and see the steps, and
#' [dragon_import()] to bring the results back into this run directory.
#'
#' @inheritParams dragon_train
#' @param method For a dataset mapped with [dragon_map_pairs()], the
#'   preference method, `"dpo"` or `"orpo"`. Defaults to `"dpo"`. Ignored for
#'   prompt and response data.
#' @param beta Preference strength for `method`, or the KL weight for an RL
#'   run. Defaults to 0.1 and 0.04 respectively.
#' @param rewards For a dataset mapped with [dragon_map_prompts()], the
#'   [dragon_reward()] list an RL run needs.
#' @param group_size,temperature,max_new_tokens RL sampling settings. See
#'   [dragon_reinforce()].
#' @return A `dragon_run` whose state is `"bundled"`.
#' @export
#' @examples
#' if (interactive()) {
#' run <- dragon_dataset(dragon_example_data()) |>
#'   dragon_map(prompt = "{subject}\n\n{body}", response = "reply") |>
#'   dragon_bundle("Qwen/Qwen2.5-0.5B-Instruct")
#' dragon_remote(run, "colab")
#' # ... train in the browser, download the results zip ...
#' dragon_import(run, "~/Downloads/dragonfarm-results-<run id>.zip")
#' dragon_generate(run, "My thermostat keeps dropping off Wi-Fi.")
#' }
dragon_bundle <- function(dataset, model, lora = dragon_lora(), args = dragon_train_args(),
                          name = NULL, run_dir = NULL, runs_dir = dragon_runs_dir(),
                          n_samples = 10, revision = NULL, trust_remote_code = FALSE,
                          method = NULL, beta = NULL, rewards = NULL, group_size = 4,
                          temperature = 1.0, max_new_tokens = 128) {
  check_dataset(dataset)
  stage <- switch(mapping_kind(dataset) %||% "messages", pairs = "prefer", prompts = "reinforce", "sft")
  prefer <- NULL
  reinforce <- NULL
  if (stage == "prefer") {
    method <- if (is.null(method)) "dpo" else match.arg(method, c("dpo", "orpo"))
    beta <- beta %||% 0.1
    check_number(beta, "beta", min = 1e-4, max = 10)
    prefer <- list(method = method, beta = beta)
  } else if (stage == "reinforce") {
    if (is.null(rewards)) cli::cli_abort("This dataset is mapped as RL prompts; pass {.arg rewards} (see {.fn dragon_reward}).")
    beta <- beta %||% 0.04
    check_number(beta, "beta", min = 0, max = 10)
    check_number(group_size, "group_size", min = 2, max = 64, integer = TRUE)
    check_number(temperature, "temperature", min = 0.05, max = 3)
    check_number(max_new_tokens, "max_new_tokens", min = 1, integer = TRUE)
    reinforce <- list(rewards = as_reward_specs(rewards), group_size = as.integer(group_size), beta = beta,
                      temperature = temperature, max_new_tokens = as.integer(max_new_tokens))
  }
  prep <- prepare_run(dataset, model, lora, args, dragon_hardware(), name, run_dir, runs_dir,
                      n_samples, revision = revision, trust_remote_code = trust_remote_code,
                      state = "bundled", check_token = FALSE, stage = stage, prefer = prefer, reinforce = reinforce)
  run <- new_run(prep$run_dir)
  paths <- bundle_run(run)
  cli::cli_alert_success("Bundled run {.strong {run$id}} ({prep$files$n_train} training rows, {prep$files$n_eval} held out).")
  cli::cli_text("Bundle: {.path {paths$zip}} ({file_size_label(paths$zip)})")
  cli::cli_text("Next: {.code dragon_remote(run, \"colab\")} (or {.val kaggle}, {.val lightning}, {.val runpod}).")
  run
}

file_size_label <- function(path) {
  format(structure(file.size(path), class = "object_size"), units = "auto")
}

# Build <run>/remote/: the zip plus per-provider helper files. Works for any
# run directory, including one that trained (or failed) locally.
bundle_run <- function(run) {
  run <- dragon_run(run)
  cfg <- run_config(run)
  paths <- bundle_paths(run)
  dir.create(paths$bundle_dir, recursive = TRUE, showWarnings = FALSE)

  staging <- tempfile("dragonfarm-bundle-")
  dir.create(file.path(staging, "run", "data"), recursive = TRUE)
  on.exit(unlink(staging, recursive = TRUE), add = TRUE)

  # The cloud machine decides the device; a local "cpu" choice must not follow the run.
  cfg$hardware <- list(device = "auto", dtype = "auto", load_in_4bit = FALSE)
  cfg$bundle <- list(created_at = now_iso(), dragonfarm = as.character(utils::packageVersion("dragonfarm")))
  write_json(cfg, file.path(staging, "run", "config.json"))
  for (rel in c(cfg$data$train, cfg$data$eval)) {
    if (is.null(rel)) next
    src <- run_path(run, rel)
    if (!file.exists(src)) cli::cli_abort("Run {.strong {run$id}} is missing {.path {rel}}; it cannot be bundled.")
    dir.create(dirname(file.path(staging, "run", rel)), recursive = TRUE, showWarnings = FALSE)
    file.copy(src, file.path(staging, "run", rel))
  }
  if (file.exists(run_path(run, "dataset.json"))) {
    file.copy(run_path(run, "dataset.json"), file.path(staging, "run", "dataset.json"))
  }
  for (extra in c("base_adapters", "rewards")) {
    if (dir.exists(run_path(run, extra))) file.copy(run_path(run, extra), file.path(staging, "run"), recursive = TRUE)
  }
  write_json(list(state = "queued", created_at = now_iso(), pid = NULL), file.path(staging, "run", "status.json"))

  py_dir <- file.path(staging, "python", "dragonfarm")
  dir.create(py_dir, recursive = TRUE)
  py_files <- list.files(file.path(python_source_dir(), "dragonfarm"), pattern = "\\.py$", full.names = TRUE)
  file.copy(py_files, py_dir)
  writeLines(dragon_python_requirements()$packages, file.path(staging, "requirements.txt"))
  file.copy(remote_notebook_source(), file.path(staging, remote_notebook_file))
  writeLines(remote_readme(run, paths), file.path(staging, "README.md"))

  zip::zip(normalizePath(paths$zip, winslash = "/", mustWork = FALSE), files = list.files(staging), root = staging)

  file.copy(remote_notebook_source(), paths$notebook, overwrite = TRUE)
  write_json(kaggle_kernel_metadata(run), paths$kernel_meta)
  write_json(kaggle_dataset_metadata(run), paths$dataset_meta)
  writeLines(remote_readme(run, paths), paths$readme)

  st <- read_json(run_path(run, "status.json"))
  st$remote <- utils::modifyList(st$remote %||% list(), list(bundle = paths$zip, bundled_at = now_iso()))
  write_json(st, run_path(run, "status.json"))
  invisible(paths)
}

# Kaggle CLI metadata, so `kaggle datasets create` and `kaggle kernels push`
# work from the remote/ folder without editing anything.
kaggle_username <- function() {
  u <- Sys.getenv("KAGGLE_USERNAME")
  if (nzchar(u)) return(u)
  f <- file.path(Sys.getenv("KAGGLE_CONFIG_DIR", file.path(path.expand("~"), ".kaggle")), "kaggle.json")
  if (file.exists(f)) {
    u <- tryCatch(read_json(f)$username, error = function(e) NULL)
    if (!is.null(u) && nzchar(u)) return(u)
  }
  "YOUR-KAGGLE-USERNAME"
}

kaggle_slug <- function(run) {
  slug <- substr(paste0("dragonfarm-", slugify(run$id)), 1, 50)
  sub("-+$", "", slug)
}

kaggle_dataset_metadata <- function(run) {
  list(
    title = substr(paste("dragonfarm", run$id), 1, 50),
    id = paste0(kaggle_username(), "/", kaggle_slug(run)),
    licenses = list(list(name = "unknown"))
  )
}

kaggle_kernel_metadata <- function(run) {
  ds <- kaggle_dataset_metadata(run)
  list(
    id = ds$id,
    title = ds$title,
    code_file = remote_notebook_file,
    language = "python",
    kernel_type = "notebook",
    is_private = TRUE,
    enable_gpu = TRUE,
    enable_tpu = FALSE,
    enable_internet = TRUE,
    dataset_sources = list(ds$id),
    competition_sources = list(),
    kernel_sources = list(),
    model_sources = list()
  )
}

# Plain-text steps for one provider. Used by dragon_remote(), the bundle
# README, and the Shiny app.
remote_steps <- function(provider, run, paths = bundle_paths(run), app = FALSE, saved = FALSE) {
  check_provider(provider)
  zipname <- basename(paths$zip)
  results <- results_name(run)
  import_line <- sprintf('dragon_import(dragon_run("%s"), "%s")', run$dir, results)
  url <- remote_url(provider)
  # In the app nobody types code: results are picked up from Downloads, or
  # imported with a button in Monitor.
  back <- if (app) "dragonfarm imports the results as soon as they land in your Downloads folder (or import them in Monitor)."
          else sprintf("Back in R: %s", import_line)
  where <- if (saved) sprintf("%s (in your Downloads folder)", zipname) else zipname
  switch(provider,
    colab = c(
      if (app) "dragonfarm opens the notebook in Colab, with a free T4 GPU already chosen." else sprintf("Open the notebook in Colab: %s", url),
      sprintf("Press Runtime > Run all, and pick %s when it asks for a file.", where),
      sprintf("When it finishes, Colab downloads %s by itself.", results),
      back
    ),
    kaggle = c(
      if (app) "dragonfarm opens the notebook in Kaggle." else
        sprintf("Open the notebook in Kaggle: %s (if Kaggle opens without it, use File > Import Notebook > Link and paste %s).", url, notebook_github_url()),
      "Session options (right sidebar): Accelerator = GPU T4 x2 or GPU P100, Internet = On. Kaggle asks for phone verification the first time.",
      sprintf("Input > Upload > New Dataset: upload %s. It lands under /kaggle/input, where the notebook looks for it.", where),
      "Run All.",
      sprintf("%s appears under Output when the notebook finishes. Download it.", results),
      back,
      if (!app) sprintf("Or from a terminal with the Kaggle CLI, using the metadata already written: kaggle datasets create -p \"%s\" then kaggle kernels push -p \"%s\" then kaggle kernels output %s -p .",
                        paths$bundle_dir, paths$dir, kaggle_kernel_metadata(run)$id)
    ),
    lightning = c(
      sprintf("Open a Studio from the dragonfarm repository%s", if (app) " (dragonfarm opens it)." else paste0(": ", url)),
      "Switch the Studio to a GPU machine (machine picker, top right). A T4 is enough for models up to 1.5B parameters.",
      sprintf("Drag %s into the Studio file browser, open %s, and run all cells.", where, remote_notebook_repo_path),
      sprintf("Download %s from the file browser when the last cell finishes.", results),
      back
    ),
    runpod = c(
      sprintf("Deploy a pod from the \"RunPod PyTorch\" template on a GPU with 16 GB or more%s", if (app) " (dragonfarm opens the RunPod console)." else paste0(": ", url)),
      sprintf("Connect > Jupyter Lab. Upload %s and %s (both in %s), then run all cells.", where, remote_notebook_file, paths$dir),
      sprintf("Download %s from the Jupyter file browser when the last cell finishes.", results),
      "Stop the pod so billing stops.",
      back
    )
  )
}

# Is the app's browser on this machine? Then files can go straight to its
# Downloads folder and links can open in the system browser.
is_local_session <- function(session) {
  host <- session$clientData$url_hostname %||% ""
  host %in% c("localhost", "127.0.0.1", "::1", "[::1]")
}

# Open a link in the system browser (a function of its own so tests can
# stand in for it).
open_in_browser <- function(url) invisible(try(utils::browseURL(url), silent = TRUE))

# Copy a file into Downloads; returns the new path, or NULL if there is no
# Downloads folder or the copy failed.
save_to_downloads <- function(path) {
  d <- downloads_dir()
  if (is.null(d)) return(NULL)
  to <- file.path(d, basename(path))
  if (isTRUE(file.copy(path, to, overwrite = TRUE))) to
}

# Where the browser saves downloads on this machine; NULL when there is no
# such folder. options(dragonfarm.downloads_dir) overrides it.
downloads_dir <- function() {
  d <- getOption("dragonfarm.downloads_dir")
  if (!is.null(d)) return(if (dir.exists(d)) d)
  home <- if (is_windows()) Sys.getenv("USERPROFILE", unset = path.expand("~")) else path.expand("~")
  d <- file.path(home, "Downloads")
  if (dir.exists(d)) d
}

# A run's results zip that has landed in a folder, newest first. Browsers
# write to a temporary name (.crdownload, .part) until the download is
# complete, so a file with the final name is whole. Repeats get " (1)".
find_results <- function(run, dir = downloads_dir(), since = NULL) {
  if (is.null(dir) || !dir.exists(dir)) return(NULL)
  base <- sub("[.]zip$", "", results_name(run))
  f <- list.files(dir, full.names = TRUE)
  b <- basename(f)
  f <- f[startsWith(b, base) & endsWith(b, ".zip")]
  if (!is.null(since)) f <- f[file.mtime(f) >= since]
  if (!length(f)) return(NULL)
  f[which.max(file.mtime(f))]
}

remote_readme <- function(run, paths = bundle_paths(run)) {
  providers <- dragon_remote_providers()
  out <- c(
    sprintf("# dragonfarm run %s: train on a cloud GPU", run$id),
    "",
    sprintf("This folder holds `%s`, a self-contained bundle: the training data in chat format,", basename(paths$zip)),
    "the run configuration, the dragonfarm trainer, and a notebook that runs it on any",
    "machine with a GPU. Pick a provider, follow its steps, then bring the results back",
    "into R with `dragon_import()`.",
    ""
  )
  for (i in seq_len(nrow(providers))) {
    p <- providers$provider[i]
    out <- c(out, sprintf("## %s (%s)", providers$name[i], providers$cost[i]), "",
             sprintf("%d. %s", seq_along(remote_steps(p, run, paths)), remote_steps(p, run, paths)), "")
  }
  out
}

#' Open a cloud GPU provider for a bundled run
#'
#' Prints the steps for running a bundled run on the chosen provider and, by
#' default in an interactive session, opens the provider in the browser with
#' the dragonfarm notebook loaded. Runs that were not bundled yet are bundled
#' first, so a run that failed locally for lack of memory can be sent to the
#' cloud as is.
#'
#' @param run A `dragon_run` or run directory.
#' @param provider One of `"colab"`, `"kaggle"`, `"lightning"`, `"runpod"`.
#'   See [dragon_remote_providers()].
#' @param open Open the provider link in the browser.
#' @return Invisibly, a list with `provider`, `url`, `bundle` (path to the
#'   zip), and `steps` (a character vector).
#' @export
#' @examples
#' if (interactive()) {
#' dragon_remote(run, "kaggle")
#' }
dragon_remote <- function(run, provider = c("colab", "kaggle", "lightning", "runpod"),
                          open = interactive()) {
  run <- dragon_run(run)
  provider <- match.arg(provider)
  st <- dragon_status(run)
  if (identical(st$state, "running")) {
    cli::cli_abort("Run {.strong {run$id}} is training locally right now. Cancel it first with {.fn dragon_cancel}.")
  }
  paths <- bundle_paths(run)
  if (!file.exists(paths$zip)) paths <- bundle_run(run)
  url <- remote_url(provider)
  steps <- remote_steps(provider, run, paths)

  cli::cli_h2("Train {run$id} on {provider_name(provider)}")
  cli::cli_text("Bundle: {.path {paths$zip}} ({file_size_label(paths$zip)})")
  cli::cli_ol()
  for (s in steps) cli::cli_li("{s}")
  cli::cli_end()

  st <- read_json(run_path(run, "status.json"))
  st$remote <- utils::modifyList(st$remote %||% list(), list(provider = provider, url = url, opened_at = now_iso()))
  write_json(st, run_path(run, "status.json"))

  if (isTRUE(open)) utils::browseURL(url)
  invisible(list(provider = provider, url = url, bundle = paths$zip, steps = steps))
}

#' Import results trained on another machine
#'
#' Copies the outputs of a run that trained elsewhere (through
#' [dragon_remote()]) back into the local run directory: the adapter, the
#' status, the progress log, the evaluation, and the sample generations.
#' Afterwards [dragon_status()], [dragon_progress()], [dragon_evaluate()],
#' [dragon_generate()], and [dragon_merge()] work as if the run had trained
#' locally.
#'
#' @param run A `dragon_run` or run directory.
#' @param results Path to the `dragonfarm-results-<run id>.zip` the notebook
#'   produced, or to a directory holding its unpacked contents.
#' @return The run, invisibly.
#' @export
#' @examples
#' if (interactive()) {
#' dragon_import(run, "~/Downloads/dragonfarm-results-20260914-101500-qwen2-5-0-5b-instruct.zip")
#' }
dragon_import <- function(run, results) {
  run <- dragon_run(run)
  check_string(results, "results")
  if (!file.exists(results)) cli::cli_abort("{.path {results}} does not exist.")

  src <- results
  if (!dir.exists(results)) {
    src <- tempfile("dragonfarm-results-")
    dir.create(src)
    on.exit(unlink(src, recursive = TRUE), add = TRUE)
    zip::unzip(results, exdir = src)
  }
  manifest_path <- file.path(src, "dragonfarm-results.json")
  if (!file.exists(manifest_path)) {
    cli::cli_abort(c(
      "{.path {results}} is not a dragonfarm results archive.",
      "i" = "Expected the {.file {results_name(run)}} file that the last notebook cell produces."
    ))
  }
  manifest <- read_json(manifest_path)
  if (!identical(manifest$run_id, run$id)) {
    cli::cli_warn("These results are from a different run ({.val {manifest$run_id}}); importing into {.strong {run$id}} anyway.")
  }

  for (f in c("status.json", "progress.jsonl", "log.txt", "eval.json", "samples.json")) {
    if (file.exists(file.path(src, f))) file.copy(file.path(src, f), run_path(run, f), overwrite = TRUE)
  }
  if (dir.exists(file.path(src, "adapter"))) {
    unlink(run_path(run, "adapter"), recursive = TRUE)
    file.copy(file.path(src, "adapter"), run$dir, recursive = TRUE)
  }

  st <- read_json(run_path(run, "status.json"))
  st$pid <- NULL
  st$imported_at <- now_iso()
  st$remote <- utils::modifyList(st$remote %||% list(), list(
    results = normalizePath(results, winslash = "/"),
    trained_on = manifest$device %||% st$device_name %||% NULL
  ))
  write_json(st, run_path(run, "status.json"))

  msg <- "Imported results for {.strong {run$id}}: state {.strong {st$state}}"
  if (!is.null(st$device_name)) msg <- paste0(msg, ", trained on {st$device_name}")
  if (!is.null(st$eval_loss)) msg <- paste0(msg, ", eval loss {round(st$eval_loss, 3)}")
  cli::cli_alert_success(paste0(msg, "."))
  if (file.exists(run_path(run, "adapter", "adapter_config.json"))) {
    cli::cli_text("Try it: {.code dragon_generate(run, \"...\")}, or save a standalone model with {.code dragon_merge(run)}.")
  }
  invisible(run)
}
