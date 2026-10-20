mem_run <- function(runs, id, model, state, error = NULL, gc = FALSE, created = "2026-10-17T10:00:00Z") {
  d <- file.path(runs, id); dir.create(d, recursive = TRUE)
  jsonlite::write_json(list(stage = "sft", created_at = created, model = list(id = model), hardware = list(load_in_4bit = TRUE),
                            train = list(per_device_batch_size = 1, gradient_accumulation = 16, max_seq_len = 1536,
                                         gradient_checkpointing = gc)),
                       file.path(d, "config.json"), auto_unbox = TRUE)
  st <- list(state = state, created_at = created, started_at = "2026-10-17T10:00:00Z", finished_at = "2026-10-17T10:30:00Z",
             device_name = "RTX 4060")
  if (!is.null(error)) st$error <- error
  jsonlite::write_json(st, file.path(d, "status.json"), auto_unbox = TRUE)
}

test_that("past training runs are recalled with settings and how they ended", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  mem_run(runs, "20261017-100000-a", "Qwen/Qwen2.5-3B-Instruct", "failed", error = "AcceleratorError: CUDA error: out of memory",
          created = "2026-10-17T10:00:00Z")
  mem_run(runs, "20261017-110000-b", "Qwen/Qwen2.5-3B-Instruct", "succeeded", gc = TRUE, created = "2026-10-17T11:00:00Z")
  mem_run(runs, "20261017-120000-c", "Qwen/Qwen2.5-0.5B-Instruct", "succeeded", created = "2026-10-17T12:00:00Z")
  all <- dragonfarm:::training_outcomes(runs_dir = runs)
  expect_length(all, 3)
  three <- dragonfarm:::training_outcomes(model = "Qwen/Qwen2.5-3B-Instruct", runs_dir = runs)
  expect_equal(vapply(three, `[[`, "", "state"), c("succeeded", "failed"))
  oom <- three[[2]]
  expect_equal(oom$error_code, "OUT_OF_MEMORY"); expect_false(oom$gradient_checkpointing); expect_equal(oom$max_seq_len, 1536)
  expect_true(three[[1]]$gradient_checkpointing); expect_equal(three[[1]]$minutes, 30)
  expect_equal(three[[1]]$trainer, "transformers")          # runs from before D-35 name no back end

  r <- tool_call("recall_training", list(model = "Qwen/Qwen2.5-3B-Instruct", limit = 1), agent = "trainer")
  expect_true(r$ok); expect_length(r$result, 1)
  expect_equal(tool_call("recall_training", list(), agent = "answer")$code, "NOT_ALLOWED")
})

test_that("old error text without a code is still classified", {
  expect_equal(dragonfarm:::legacy_error_code("Returning 2 (CUDA_ERROR_OUT_OF_MEMORY) from cuMemFree_v2"), "OUT_OF_MEMORY")
  expect_equal(dragonfarm:::legacy_error_code("something else"), "UNKNOWN")
})


test_that("a run says which trainer it used and when it retried after running out of memory", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  mem_run(runs, "20261020-100000-u", "Qwen/Qwen2.5-1.5B-Instruct", "succeeded")
  st <- jsonlite::read_json(file.path(runs, "20261020-100000-u", "status.json"))
  st$backend <- "unsloth"
  st$memory_retry <- list(from = list(per_device_batch_size = 4), to = list(per_device_batch_size = 1, gradient_accumulation = 16))
  jsonlite::write_json(st, file.path(runs, "20261020-100000-u", "status.json"), auto_unbox = TRUE)
  expect_equal(dragonfarm:::training_outcomes(runs_dir = runs)[[1]]$trainer, "unsloth")
  out <- cli::cli_fmt(print(dragonfarm:::new_run(file.path(runs, "20261020-100000-u"))))
  expect_true(any(grepl("Trained with: Unsloth", out)))
  expect_true(any(grepl("ran out of GPU memory once", out)))
})
