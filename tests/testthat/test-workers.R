# Discovering and stopping dragonfarm Python processes that belong to other
# R sessions (an app left running, a console that exited without stopping
# its worker). They hold GPU memory and have caused two false out-of-memory
# diagnoses, so dragon_check() reports them and training warns about them.

withr::local_options(dragonfarm.scan_workers = TRUE)   # file scope: restored after this file

fake_procs <- function() {
  data.frame(
    pid = c(101L, 105L, 202L, 303L, 404L),
    ppid = c(1L, 101L, 1L, 1L, 1L),
    started = as.POSIXct("2026-10-13 09:00:00", tz = "UTC") + c(0, 1, 300, 600, 900),
    cmdline = c(
      # a venv launcher (101) and the interpreter it spawned (105): one worker
      "C:/py/python.exe -u -m dragonfarm.worker",
      "C:/py/python.exe -u -m dragonfarm.worker",
      "C:/py/python.exe -m dragonfarm.questions generate --dir x",
      "C:/py/python.exe -m some_other_tool",
      "C:/py/python.exe -m dragonfarm.train --run-dir r"
    ),
    stringsAsFactors = FALSE
  )
}

test_that("other dragonfarm processes are found by command line, minus our own worker and child interpreters", {
  testthat::local_mocked_bindings(
    list_python_processes = function() fake_procs(),
    own_worker_pid = function() 101L
  )
  o <- dragonfarm:::other_workers()
  expect_equal(o$pid, c(202L, 404L))
  expect_equal(o$kind, c("question generator", "trainer"))
  testthat::local_mocked_bindings(own_worker_pid = function() NA_integer_)
  expect_equal(dragonfarm:::other_workers()$pid, c(101L, 202L, 404L))
  expect_equal(dragonfarm:::other_workers()$kind[1], "inference worker")
})

test_that("dragon_worker_stop(all = TRUE) stops the other processes and reports", {
  killed <- integer()
  testthat::local_mocked_bindings(
    list_python_processes = function() fake_procs(),
    own_worker_pid = function() NA_integer_,
    kill_pid = function(pid) { killed <<- c(killed, pid); TRUE }
  )
  out <- cli::cli_fmt(dragon_worker_stop(all = TRUE))
  expect_equal(killed, c(101L, 202L, 404L))
  expect_true(any(grepl("Stopped 3 dragonfarm processes", out)))
  expect_true(any(grepl("inference worker (pid 101)", out, fixed = TRUE)))
  killed <- integer()
  testthat::local_mocked_bindings(list_python_processes = function() fake_procs()[0, ])
  dragon_worker_stop(all = TRUE)
  expect_length(killed, 0)
})

test_that("worker discovery never errors when process listing fails", {
  testthat::local_mocked_bindings(list_python_processes = function() stop("no ps here"))
  expect_equal(nrow(dragonfarm:::other_workers()), 0L)
})

test_that("the training warning names the processes and pluralises", {
  testthat::local_mocked_bindings(
    list_python_processes = function() fake_procs(),
    own_worker_pid = function() NA_integer_
  )
  out <- cli::cli_fmt(dragonfarm:::warn_other_workers("Training"))
  expect_true(any(grepl("3 dragonfarm processes from other R sessions are running", out)))
  expect_true(any(grepl("stop them with", out)))
  testthat::local_mocked_bindings(list_python_processes = function() fake_procs()[3, ])
  out <- cli::cli_fmt(dragonfarm:::warn_other_workers("Training"))
  expect_true(any(grepl("1 dragonfarm process from other R sessions is running", out)))
  expect_true(any(grepl("stop it with", out)))
  testthat::local_mocked_bindings(list_python_processes = function() fake_procs()[0, ])
  expect_length(cli::cli_fmt(dragonfarm:::warn_other_workers()), 0)
})

test_that("a heavy GPU job is refused while another one runs, unless allowed", {
  busy <- data.frame(pid = 4242L, kind = "trainer", started = Sys.time())
  testthat::local_mocked_bindings(other_workers = function() busy)
  err <- tryCatch(dragonfarm:::require_gpu_free("Training"), error = function(e) e)
  expect_s3_class(err, "dragonfarm_error")
  expect_equal(err$code, "GPU_BUSY")
  expect_match(conditionMessage(err), "trainer (pid 4242)", fixed = TRUE)
  withr::local_options(dragonfarm.allow_parallel_gpu = TRUE)
  expect_true(dragonfarm:::require_gpu_free("Training"))
})

test_that("another session's answering worker does not block a heavy job", {
  testthat::local_mocked_bindings(other_workers = function() data.frame(pid = 7L, kind = "inference worker", started = Sys.time()))
  expect_true(dragonfarm:::require_gpu_free("Training"))
})
