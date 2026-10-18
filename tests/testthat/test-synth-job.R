# D-16: a teacher writes replies in the background; local by default, an
# outside teacher only when chosen, recorded, and never with a key on disk.

test_that("the job runs the teacher, writes a status, and records an outside teacher", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  withr::local_envvar(ANTHROPIC_API_KEY = "sk-ant-JOBPROBE")
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  launched <- NULL
  testthat::local_mocked_bindings(launch_rscript = function(script, log) { launched <<- script; invisible(NULL) })
  job <- dragonfarm:::synth_job_start(c("How do I reset it?", "Where is my order?"), list(kind = "anthropic", model = "claude-sonnet-5"),
                                      runs_dir = runs)
  expect_true(file.exists(launched))
  spec_file <- sub("[.]json$", ".rds", job$status)
  expect_false(length(grepRaw("JOBPROBE", readBin(spec_file, "raw", file.size(spec_file)), fixed = TRUE)) > 0)   # no key saved
  expect_equal(dragonfarm:::synth_job_status(job$status)$state, "queued")
  ev <- dragonfarm:::store_events(5, kind = "approval_decision", runs_dir = runs)
  expect_equal(ev$name, "synthesize_with_outside_teacher")

  testthat::local_mocked_bindings(
    require_gpu_free = function(...) invisible(TRUE),
    dragon_synthesize = function(prompts, teacher, system = NULL, runs_dir, name) {
      f <- file.path(runs_dir, "synth.jsonl"); dragonfarm:::write_jsonl(list(list(prompt = prompts[1], response = "Hold 10 s.")), f)
      structure(dragon_map(dragon_dataset(f), prompt = "prompt", response = "response"),
                synthesis = list(teacher = "anthropic:claude-sonnet-5", dropped = list(empty = 1)))
    }
  )
  dragonfarm:::synth_job_run(spec_file)
  st <- dragonfarm:::synth_job_status(job$status)
  expect_equal(st$state, "succeeded"); expect_equal(st$n_kept, 1); expect_equal(st$dropped, 1)
})

test_that("a local teacher is not recorded as outbound and fails cleanly when the GPU is busy", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  testthat::local_mocked_bindings(launch_rscript = function(...) invisible(NULL),
    require_gpu_free = function(...) stop(structure(class = c("dragonfarm_error", "error", "condition"),
                                                    list(message = "busy", code = "GPU_BUSY"))))
  job <- dragonfarm:::synth_job_start("Hi", list(kind = "local", model = "Qwen/Qwen2.5-0.5B-Instruct"), runs_dir = runs)
  expect_equal(nrow(dragonfarm:::store_events(5, kind = "approval_decision", runs_dir = runs)), 0)
  dragonfarm:::synth_job_run(sub("[.]json$", ".rds", job$status))
  st <- dragonfarm:::synth_job_status(job$status)
  expect_equal(st$state, "failed"); expect_equal(st$code, "GPU_BUSY")
})

test_that("the Map step starts a job and loads the replies when it is done", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  f <- file.path(runs, "out.jsonl"); dragonfarm:::write_jsonl(list(list(prompt = "a", response = "b")), f)
  status <- file.path(runs, "st.json")
  started <- NULL
  testthat::local_mocked_bindings(synth_job_start = function(prompts, teacher, system = NULL, ...) {
    started <<- teacher
    dragonfarm:::write_json(list(state = "succeeded", file = f, n_kept = 1, n_prompts = 1, dropped = 0, teacher = "local:m"), status)
    list(id = "j", status = status)
  })
  ds <- dragon_map(dragon_dataset(data.frame(q = c("x", "y"), a = c("1", "2"))), prompt = "q", response = "a")
  state <- shiny::reactiveValues(dataset = ds, mapped = ds, hardware = list(tier = list(model = "Qwen/Qwen2.5-3B-Instruct")))
  shiny::testServer(dragonfarm:::mod_mapping_server, args = list(state = state, nav_to = function(p) NULL), {
    session$setInputs(teacher_kind = "local", teacher_model = "", teacher_n = 10, teach = 1)
    session$flushReact()
    expect_equal(started$model, "Qwen/Qwen2.5-3B-Instruct")         # the model recommended for this machine
    expect_equal(nrow(state$mapped$data), 1)                         # the replies are loaded
    session$setInputs(teacher_kind = "anthropic", teach = 2)
  })
})
