#' Python requirements used by dragonfarm
#'
#' The package declares these with [reticulate::py_require()] when it is
#' loaded. You normally never call this yourself.
#'
#' @return A list with `packages` (pip requirement strings) and `python_version`.
#' @export
#' @examples
#' dragon_python_requirements()
dragon_python_requirements <- function() {
  list(
    packages = c(
      "torch>=2.4",
      "transformers>=4.46",
      "peft>=0.13",
      "accelerate>=1.0",
      "safetensors>=0.4",
      "numpy",
      "sentencepiece",
      "protobuf",
      "huggingface_hub>=0.25",
      # document readers (dragon_documents): pure Python, small
      "pypdf>=4",
      "cryptography>=3.1",   # pypdf needs it for AES-encrypted PDFs (common, even without a password)
      "python-docx>=1.1",
      "openpyxl>=3.1",
      # 4-bit loading on NVIDIA GPUs; no macOS build, so it is left out there
      "bitsandbytes>=0.45; platform_system != 'Darwin'"
    ),
    python_version = ">=3.10,<3.14"
  )
}

# The locked set: inst/python/requirements.lock pins every package with
# hashes, for building environments on servers and machines without the
# internet (scripts/lock_python.R regenerates it). Its header records a hash
# of the requirements it was resolved from, so a stale lock is caught.
requirements_hash <- function(reqs = dragon_python_requirements()) {
  rlang::hash(paste(c(reqs$packages, reqs$python_version), collapse = "\n"))
}

lock_path <- function() system.file("python", "requirements.lock", package = "dragonfarm")

# name -> version for every pinned package, names normalised as pip does.
lock_pins <- function(path = lock_path()) {
  if (!nzchar(path) || !file.exists(path)) return(character())
  lines <- readLines(path, warn = FALSE)
  m <- Filter(length, regmatches(lines, regexec("^([A-Za-z0-9._-]+)==([^ ;\\\\]+)", lines)))
  stats::setNames(vapply(m, `[`, "", 3), normalise_package(vapply(m, `[`, "", 2)))
}

normalise_package <- function(x) gsub("[-_.]+", "-", tolower(x))

# What the environment is built from (D-12): the locked set, every package
# pinned exactly with its platform marker, so two machines get the same
# versions and nothing drifts as new releases appear. The loose requirements
# are used instead when the lock does not match them (its header records
# their hash) or when DRAGONFARM_PYTHON_LOCKED=false or
# options(dragonfarm.python_locked = FALSE) asks for the latest releases.
locked_requirements <- function(path = lock_path(), reqs = dragon_python_requirements()) {
  if (!nzchar(path) || !file.exists(path)) return(NULL)
  lines <- readLines(path, warn = FALSE)
  if (!any(lines == paste("# requirements:", requirements_hash(reqs)))) return(NULL)
  m <- regmatches(lines, regexec("^([A-Za-z0-9._-]+==[^ ;\\\\]+)\\s*(;\\s*([^\\\\]+?))?\\s*\\\\?\\s*$", lines))
  m <- Filter(length, m)
  if (!length(m)) return(NULL)
  vapply(m, function(x) if (nzchar(x[4])) paste0(x[2], " ; ", trimws(x[4])) else x[2], "")
}

python_env_requirements <- function() {
  reqs <- dragon_python_requirements()
  off <- isFALSE(getOption("dragonfarm.python_locked")) || tolower(Sys.getenv("DRAGONFARM_PYTHON_LOCKED")) %in% c("false", "0", "no")
  pinned <- if (off) NULL else locked_requirements(reqs = reqs)
  # The lock was resolved for one Python and later ("resolved for Python 3.12");
  # older interpreters may not install every pinned version.
  pyv <- reqs$python_version
  if (!is.null(pinned)) {
    hdr <- grep("^# resolved for Python [0-9.]+", readLines(lock_path(), n = 10, warn = FALSE), value = TRUE)
    if (length(hdr)) pyv <- sprintf(">=%s,<3.14", sub("^# resolved for Python ([0-9.]+).*$", "\\1", hdr[1]))
  }
  list(packages = pinned %||% reqs$packages, python_version = pyv, locked = !is.null(pinned))
}

# Installed packages in an interpreter, name -> version.
python_packages <- function(py) {
  code <- "import json, importlib.metadata as m; print(json.dumps({d.metadata['Name']: d.version for d in m.distributions()}))"
  res <- processx::run(py, c("-c", code), error_on_status = FALSE, windows_hide_window = TRUE)
  if (res$status != 0) return(NULL)
  v <- unlist(jsonlite::fromJSON(res$stdout))
  stats::setNames(as.character(v), normalise_package(names(v)))
}

# Installed packages whose version differs from the lock. A local build such
# as torch "2.14.1+cu130" matches a lock pin of "2.14.1".
lock_drift <- function(installed, pins = lock_pins()) {
  common <- intersect(names(installed), names(pins))
  base <- sub("[+].*$", "", installed[common])
  bad <- common[base != pins[common]]
  data.frame(package = bad, locked = unname(pins[bad]), installed = unname(installed[bad]))
}

# Path to the Python interpreter that has the declared requirements.
# Cached per session. Set DRAGONFARM_PYTHON to bypass reticulate entirely and
# use an interpreter you manage yourself.
dragon_python <- function(quiet = FALSE) {
  if (!is.null(the$python) && file.exists(the$python)) return(the$python)
  override <- Sys.getenv("DRAGONFARM_PYTHON", unset = "")
  if (nzchar(override)) {
    if (!file.exists(override)) cli::cli_abort("DRAGONFARM_PYTHON points to {.path {override}}, which does not exist.")
    the$python <- override
    return(override)
  }
  if (!quiet) {
    cli::cli_alert_info("Preparing the Python environment. The first time this downloads torch and transformers (2 to 3 GB) and can take several minutes.")
  }
  if (configure_torch_index() && !quiet) {
    cli::cli_alert_info("NVIDIA GPU detected: using the CUDA build of torch from {.url {Sys.getenv('UV_EXTRA_INDEX_URL')}}. Set {.envvar DRAGONFARM_TORCH_INDEX} to \"\" to use the CPU build instead.")
  }
  py <- if (isTRUE(getOption("dragonfarm.python_in_child"))) python_from_child() else {
    reticulate::py_config()
    reticulate::py_exe()
  }
  if (is.null(py) || !nzchar(py)) cli::cli_abort("reticulate could not report a Python executable.")
  the$python <- py
  py
}

# Find the Python environment from a child R process that has no stdin.
# reticulate starts uv and Python helpers that inherit this process's stdin;
# under an MCP server that is the client's open message stream, so they wait
# on it for ever. The child declares the same requirements, so it resolves
# the same cached environment.
python_from_child <- function() {
  reqs <- python_env_requirements()
  script <- tempfile(fileext = ".R")
  on.exit(unlink(script), add = TRUE)
  writeLines(c(
    sprintf("reticulate::py_require(%s, python_version = %s)", paste(deparse(reqs$packages), collapse = ""),
            deparse(reqs$python_version)),
    "reticulate::py_config()",
    "cat('\\nDRAGONFARM_PYTHON=', reticulate::py_exe(), '\\n', sep = '')"
  ), script)
  p <- processx::process$new(file.path(R.home("bin"), "Rscript"), script, stdin = NULL, stdout = "|", stderr = "|",
                             windows_hide_window = TRUE)
  out <- character()
  while (p$is_alive() || p$is_incomplete_output()) {
    p$poll_io(1000)
    out <- c(out, p$read_output_lines())
    p$read_error_lines()
  }
  line <- grep("^DRAGONFARM_PYTHON=", out, value = TRUE)
  if (!length(line)) cli::cli_abort("Could not prepare the Python environment in a child process.")
  sub("^DRAGONFARM_PYTHON=", "", line[length(line)])
}

python_source_dir <- function() {
  d <- system.file("python", package = "dragonfarm")
  if (!nzchar(d)) cli::cli_abort("Bundled Python sources not found. Is dragonfarm installed correctly?")
  d
}

python_env <- function() {
  c(
    "current",
    PYTHONPATH = python_source_dir(),
    DRAGONFARM_MANAGED = "1",
    PYTHONUNBUFFERED = "1",
    PYTHONIOENCODING = "utf-8",
    HF_HUB_DISABLE_PROGRESS_BARS = "1",
    TQDM_DISABLE = "1",
    TOKENIZERS_PARALLELISM = "false"
  )
}

# Run a dragonfarm Python module to completion and return the processx result.
run_python <- function(module, args = character(), timeout = Inf, echo = FALSE) {
  py <- dragon_python()
  processx::run(
    py, c("-m", module, args),
    env = python_env(), error_on_status = FALSE, timeout = timeout,
    echo = echo, windows_hide_window = TRUE
  )
}

python_failure_message <- function(res, what) {
  err <- trimws(res$stderr)
  tail <- paste(utils::tail(strsplit(err, "\n")[[1]], 15), collapse = "\n")
  cli::cli_abort(c(
    "{what} failed (exit status {res$status}).",
    "i" = "Last lines of Python output:",
    " " = tail
  ))
}

#' Check the Python environment and hardware
#'
#' Prepares the Python environment if needed, then reports the interpreter,
#' library versions, the compute device that training will use, available
#' GPU memory, and whether a Hugging Face token is configured. Run this first
#' on a new machine.
#'
#' @return Invisibly, a list of the collected facts.
#' @export
#' @examples
#' if (interactive()) {
#' dragon_check()
#' }
dragon_check <- function() {
  cli::cli_h1("dragonfarm environment check")
  result <- list(ok = FALSE)

  py <- tryCatch(dragon_python(), error = function(e) {
    cli::cli_alert_danger("Python environment could not be prepared: {conditionMessage(e)}")
    NULL
  })
  if (is.null(py)) return(invisible(result))
  result$python <- py
  cli::cli_alert_success("Python: {.path {py}}")
  # An environment an admin built (DRAGONFARM_PYTHON) is compared with the
  # locked set, so two machines can be shown to be the same.
  if (nzchar(Sys.getenv("DRAGONFARM_PYTHON")) && length(lock_pins())) {
    installed <- python_packages(py)
    if (!is.null(installed)) {
      drift <- lock_drift(installed)
      result$lock_drift <- drift
      if (nrow(drift)) {
        cli::cli_alert_warning("{nrow(drift)} package{?s} differ{?s/} from the locked set: {paste0(drift$package, ' ', drift$installed, ' (locked ', drift$locked, ')', collapse = ', ')}.")
      } else {
        cli::cli_alert_success("Python packages match the locked set ({length(intersect(names(installed), names(lock_pins())))} checked).")
      }
    }
  }

  res <- processx::run(py, c("-m", "dragonfarm.check"), env = python_env(),
                       error_on_status = FALSE, windows_hide_window = TRUE)
  if (res$status != 0) {
    cli::cli_alert_danger("Importing the Python libraries failed.")
    cli::cli_verbatim(utils::tail(strsplit(res$stderr, "\n")[[1]], 12))
    result$error <- res$stderr
    return(invisible(result))
  }
  info <- jsonlite::fromJSON(res$stdout, simplifyVector = TRUE)
  result <- c(result, info)
  the$hardware <- info

  cli::cli_alert_success("torch {info$torch} \u00b7 transformers {info$transformers} \u00b7 peft {info$peft}")
  dev <- info$device
  if (identical(dev, "cuda")) {
    cli::cli_alert_success("Device: CUDA {info$cuda_version} \u00b7 {info$device_name} \u00b7 {round(info$vram_gb, 1)} GB \u00b7 bf16 {if (isTRUE(info$bf16)) 'yes' else 'no'}")
    if (!is.null(info$bitsandbytes)) {
      cli::cli_alert_success("4-bit loading available (bitsandbytes {info$bitsandbytes}).")
    } else {
      cli::cli_alert_info("bitsandbytes not installed: models load in full precision only.")
    }
    if (!is.null(info$gpu_used_gb) && !is.na(info$gpu_used_gb)) {
      if (info$gpu_used_gb >= 1) {
        cli::cli_alert_warning("GPU memory already in use by other programs: {info$gpu_used_gb} GB ({info$gpu_free_gb} GB free). Training and 4-bit answering need most of the card.")
      } else {
        cli::cli_alert_success("GPU memory free: {info$gpu_free_gb} GB ({info$gpu_used_gb} GB in use elsewhere).")
      }
    }
  } else if (identical(dev, "mps")) {
    cli::cli_alert_success("Device: Apple MPS")
  } else {
    cli::cli_alert_warning("Device: CPU only. Training works but is slow; stick to models of 360M parameters or fewer.")
    diagnosis <- cpu_diagnosis(info$torch_cuda_build, nvidia_driver_version())
    result$cpu_reason <- diagnosis$reason
    cli::cli_bullets(diagnosis$lines)
    cli::cli_bullets(c(
      "i" = "No GPU here? Train on a cloud one instead: {.code run <- dragon_bundle(...)} then {.code dragon_remote(run, \"colab\")}. Google Colab and Kaggle are free; Lightning AI and RunPod also work. See {.help dragonfarm::dragon_remote}."
    ))
  }
  others <- other_workers()
  result$other_workers <- others
  if (nrow(others) > 0) {
    cli::cli_alert_warning("{nrow(others)} dragonfarm process{?es} from other R sessions still running: {describe_workers(others)}. Stop {cli::qty(nrow(others))}{?it/them} with {.code dragon_worker_stop(all = TRUE)} before training.")
  }
  if (!is.null(info$tier)) {
    cli::cli_alert_info("Default model for answering and question generation here: {.val {info$tier$model}}{if (isTRUE(info$tier$load_in_4bit)) ' in 4-bit' else ''} ({info$tier$label}).")
    mode <- agent_mode(info)
    result$agents <- mode$on
    if (mode$on) cli::cli_alert_success(mode$message) else cli::cli_alert_info(mode$message)
  }
  if (hf_token_present()) {
    cli::cli_alert_success("Hugging Face token found (needed for gated models such as Gemma and Llama).")
  } else {
    cli::cli_alert_info("No Hugging Face token. Open models work; gated ones need {.envvar HF_TOKEN}.")
  }
  result$ok <- TRUE
  invisible(result)
}

# Cached hardware info for the app; runs the check quietly if needed.
hardware_info <- function() {
  if (!is.null(the$hardware)) return(the$hardware)
  py <- tryCatch(dragon_python(quiet = TRUE), error = function(e) NULL)
  if (is.null(py)) return(NULL)
  res <- processx::run(py, c("-m", "dragonfarm.check"), env = python_env(),
                       error_on_status = FALSE, windows_hide_window = TRUE)
  if (res$status != 0) return(NULL)
  the$hardware <- jsonlite::fromJSON(res$stdout, simplifyVector = TRUE)
  the$hardware
}
