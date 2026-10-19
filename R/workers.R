# dragonfarm Python processes that may belong to other R sessions: an app
# left running in another console, a session that exited without stopping
# its inference worker, a question-generation job. They keep GPU memory and
# have twice made a training run look out of memory when it was not, so
# dragon_check() reports them, training warns about them, and
# dragon_worker_stop(all = TRUE) clears them.

# Every Python process on this machine, with its command line. Columns:
# pid, ppid, started, cmdline.
list_python_processes <- function() {
  procs <- ps::ps()
  procs <- procs[grepl("python", procs$name, ignore.case = TRUE), , drop = FALSE]
  if (nrow(procs) == 0) {
    return(data.frame(pid = integer(), ppid = integer(), started = as.POSIXct(character()),
                      cmdline = character(), stringsAsFactors = FALSE))
  }
  cmd <- vapply(procs$ps_handle, function(h) {
    paste(tryCatch(ps::ps_cmdline(h), error = function(e) character()), collapse = " ")
  }, character(1))
  data.frame(pid = as.integer(procs$pid), ppid = as.integer(procs$ppid), started = procs$created,
             cmdline = cmd, stringsAsFactors = FALSE)
}

own_worker_pid <- function() {
  if (!worker_alive()) return(NA_integer_)
  tryCatch(as.integer(the$worker$get_pid()), error = function(e) NA_integer_)
}

kill_pid <- function(pid) {
  h <- tryCatch(ps::ps_handle(as.integer(pid)), error = function(e) NULL)
  if (is.null(h)) return(FALSE)
  kids <- tryCatch(ps::ps_children(h, recursive = TRUE), error = function(e) list())
  for (k in kids) tryCatch(ps::ps_kill(k), error = function(e) NULL)
  !inherits(tryCatch(ps::ps_kill(h), error = function(e) e), "error")
}

worker_kind <- function(cmdline) {
  mod <- regmatches(cmdline, regexpr("dragonfarm[.][a-z_]+", cmdline))
  kinds <- c(
    "dragonfarm.worker" = "inference worker",
    "dragonfarm.questions" = "question generator",
    "dragonfarm.train" = "trainer",
    "dragonfarm.evaluate" = "evaluator",
    "dragonfarm.merge" = "merge"
  )
  out <- unname(kinds[mod])
  out[is.na(out)] <- "dragonfarm process"
  out
}

# dragonfarm processes other than this session's own inference worker, one
# row per process tree: a venv's python.exe launcher and the interpreter it
# spawns share a command line, and killing the parent takes the child with
# it. Never errors: a machine where process listing fails just reports none.
other_workers <- function() {
  # The test suite turns the scan off so its results do not depend on what
  # else happens to be running on the machine.
  if (!isTRUE(getOption("dragonfarm.scan_workers", TRUE))) {
    return(data.frame(pid = integer(), kind = character(), started = as.POSIXct(character()),
                      stringsAsFactors = FALSE))
  }
  procs <- tryCatch(list_python_processes(), error = function(e) NULL)
  empty <- data.frame(pid = integer(), kind = character(), started = as.POSIXct(character()),
                      stringsAsFactors = FALSE)
  if (is.null(procs) || nrow(procs) == 0) return(empty)
  procs <- procs[grepl("-m dragonfarm[.]", procs$cmdline), , drop = FALSE]
  own <- own_worker_pid()
  procs <- procs[!(procs$pid %in% own | procs$ppid %in% own), , drop = FALSE]
  procs <- procs[!procs$ppid %in% procs$pid, , drop = FALSE]
  if (nrow(procs) == 0) return(empty)
  data.frame(pid = procs$pid, kind = worker_kind(procs$cmdline), started = procs$started,
             stringsAsFactors = FALSE)
}

describe_workers <- function(o) {
  paste0(o$kind, " (pid ", o$pid, ")")
}

# Warn when another session's process is holding the GPU before something
# heavy starts. Returns the processes invisibly.
warn_other_workers <- function(what = "Training") {
  o <- other_workers()
  if (nrow(o) > 0) {
    cli::cli_alert_warning(paste0(
      "{nrow(o)} dragonfarm process{?es} from other R sessions {?is/are} running: {describe_workers(o)}. ",
      "{what} shares the GPU with {cli::qty(nrow(o))}{?it/them}; if it runs out of memory, stop {?it/them} with {.code dragon_worker_stop(all = TRUE)}."
    ))
  }
  invisible(o)
}

# One heavy GPU job at a time: training, question writing, evaluation, and
# merging each fill most of an 8 GB card, and two at once fail in ways that
# look like bugs. Refuse to start one while another is running (in any R
# session), unless options(dragonfarm.allow_parallel_gpu = TRUE).
heavy_kinds <- c("trainer", "question generator", "evaluator", "merge")

# D-32: another R session's inference worker also blocks a heavy job when
# this machine has a GPU. It keeps its models in GPU memory, and a DPO run
# started beside a loaded judge failed with "out of memory" minutes in
# (2026-10-18). On a CPU-only machine it holds no GPU memory, so it only
# warns. The other session is never touched; the message says how to free it.
require_gpu_free <- function(what = "This job", workers_block = gpu_machine()) {
  if (isTRUE(getOption("dragonfarm.allow_parallel_gpu", FALSE))) return(invisible(TRUE))
  o <- other_workers()
  blocking <- c(heavy_kinds, if (isTRUE(workers_block)) "inference worker")
  busy <- o[o$kind %in% blocking, , drop = FALSE]
  if (nrow(busy) > 0) {
    worker <- any(busy$kind == "inference worker")
    cli::cli_abort(c(
      "{what} would share the GPU with {describe_workers(busy)}, which is still running.",
      "i" = if (worker) "Another R session (or the app open elsewhere) has a model loaded. Free it with {.code dragon_worker_stop(all = TRUE)}; a chat there reloads its model on its next message."
            else "Wait for it to finish, or stop it ({.fn dragon_cancel} for a training run).",
      "i" = "To run both anyway, set {.code options(dragonfarm.allow_parallel_gpu = TRUE)}."
    ), class = "dragonfarm_error", code = "GPU_BUSY")
  }
  invisible(TRUE)
}

# Whether this machine has a GPU that models load onto: an NVIDIA driver, or
# Apple silicon (unified memory).
gpu_machine <- function() {
  nzchar(Sys.which("nvidia-smi")) ||
    (identical(Sys.info()[["sysname"]], "Darwin") && R.version$arch %in% c("aarch64", "arm64"))
}
